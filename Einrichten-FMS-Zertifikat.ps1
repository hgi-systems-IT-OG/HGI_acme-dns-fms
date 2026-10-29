<#
  Einrichten-FMS-Zertifikat.ps1  (hgi systems)

  Richtet auf einem FileMaker Server (Windows) die automatische Erneuerung des SSL-Zertifikats
  über Let's Encrypt mit DNS-01-Prüfung ein. Als Administrator ausführen. Normalerweise startet
  es Installieren.ps1, siehe README.

  Voraussetzungen:
    - beim Kunden: CNAME  _acme-challenge.<Domain>  ->  _acme-challenge.fm-kunde.<hgi-zone>
      Das Ziel muss mit _acme-challenge. beginnen, sonst lehnt der DNS-Dienst es ab.
      Liegt die Domain selbst in der Cloudflare-Zone von hgi, entfällt der CNAME.
    - beim DNS-Dienst: ein Client für diesen Server, der das CNAME-Ziel (ohne _acme-challenge.)
      bzw. die Domain beschreiben darf
    - in 1Password: Environment des Kunden mit FMS_DOMAIN, FMS_CNAME_TARGET, FMS_ADMIN_USER,
      FMS_ADMIN_PASSWORD, ACME_DNS_URL, ACME_DNS_CLIENT, ACME_DNS_KEY (siehe Zugang.ps1) und ein
      Service Account, der NUR dieses Environment lesen darf. Token und Environment-ID werden beim
      ersten Lauf abgefragt.

  Modi:
    Pruefen       Prüft 1Password-Zugang, Anmeldung an der Admin Console, CNAME, CAA und die
                  Versionen. Legt nur den hgi-Ordner mit dem Token an und installiert die
                  1Password CLI; an FileMaker Server und win-acme ändert es nichts.
    Staging       Richtet alles ein und holt ein TEST-Zertifikat von Let's Encrypt (Staging).
                  Kein Import, kein Neustart, kein Zeitplan. Danach Import-Skript als Dry-Run.
    Produktiv     Holt das echte Zertifikat, importiert es SOFORT (Datenbanken werden geschlossen,
                  FileMaker Server startet neu) und legt den täglichen Zeitplan an.
    Aktualisieren Bringt nur Skripte, win-acme und 1Password CLI auf den neuesten Stand.
                  Kein neues Zertifikat, kein Neustart.

  Was eingerichtet wird:
    C:\Program Files\win-acme          win-acme (installiert oder auf den neuesten Stand gebracht)
      settings.json                    Zeitplan $Uhrzeit, Skript-Timeout 1800 s, Fehlermail
    C:\Program Files\1Password CLI     op.exe (installiert oder auf den neuesten Stand gebracht)
    C:\ProgramData\hgi\Zertifikat      nur SYSTEM und Administratoren haben Zugriff
      DNS-Eintrag.ps1                  schickt den Prüfwert an den hgi-DNS-Dienst
      FMS-Zertifikat-Import.ps1        Import, Schließen, Neustart, Prüfen
      Zugang.ps1                       liest die Zugänge aus 1Password
      zugang.json                      Environment-ID und Token (DPAPI-verschlüsselt)
      pem\                             das aktuelle Zertifikat als PEM-Dateien
      Logs\
    Geplante Aufgabe "win-acme renew (acme-v02.api.letsencrypt.org)", täglich $Uhrzeit, als SYSTEM.
    win-acme erneuert, wenn das Zertifikat fällig ist, und ruft dann das Import-Skript auf.

  -ZugaengeNeu fragt Token und Environment-ID neu ab, z. B. nach einem neuen Service Account.
#>
#Requires -RunAsAdministrator
param(
    [Parameter(Mandatory)] [ValidateSet('Pruefen', 'Staging', 'Produktiv', 'Aktualisieren')] [string]$Modus,
    [string]  $AcmeEmail      = '',              # TODO: Adresse von hgi für das Let's-Encrypt-Konto (Ablaufwarnungen)
    [string]  $Uhrzeit        = '03:00:00',
    [string]  $WinAcmeOrdner  = 'C:\Program Files\win-acme',
    [string]  $SmtpServer,                       # Fehlermail von win-acme (optional)
    [int]     $SmtpPort       = 25,
    [string]  $SmtpAbsender,
    [string[]]$SmtpEmpfaenger,
    [switch]  $ZugaengeNeu,
    [switch]  $ErneuerungNeu,                    # bestehende Erneuerung für diese Domain ersetzen
    [switch]  $Ja                                # Sicherheitsabfrage im Modus Produktiv überspringen
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # Download sonst sehr langsam
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$hgiOrdner  = 'C:\ProgramData\hgi\Zertifikat'
$wacs       = Join-Path $WinAcmeOrdner 'wacs.exe'
$opOrdner   = 'C:\Program Files\1Password CLI'   # gleicher Pfad wie $opExe in Zugang.ps1
$fmsadmin   = 'C:\Program Files\FileMaker\FileMaker Server\Database Server\fmsadmin.exe'
$prodUri    = 'https://acme-v02.api.letsencrypt.org/'
$stagingUri = 'https://acme-staging-v02.api.letsencrypt.org/'

function Schritt([string]$text) { Write-Host "`n=== $text ===" -ForegroundColor Cyan }
function Ok([string]$text)      { Write-Host "  OK      $text" -ForegroundColor Green }
function Hinweis([string]$text) { Write-Host "  HINWEIS $text" -ForegroundColor Yellow }
function Abbruch([string]$text) {
    Write-Host "  FEHLER  $text" -ForegroundColor Red
    Write-Host "`nAbgebrochen." -ForegroundColor Red
    exit 1
}
function Ende([string]$text) {
    Write-Host "`n$text" -ForegroundColor Green
    Stop-Transcript | Out-Null
    exit 0
}

# DNS-Abfrage über Cloudflare (DNS over HTTPS), unabhängig vom DNS-Server des Kunden.
# Liefert die Antwort-Einträge: type 5 = CNAME, 16 = TXT, 257 = CAA.
function Get-DnsAntwort([string]$name, [string]$typ) {
    try {
        $r = Invoke-RestMethod -Uri "https://cloudflare-dns.com/dns-query?name=$name&type=$typ" `
            -Headers @{ accept = 'application/dns-json' } -TimeoutSec 20
        @($r.Answer)
    } catch {
        Hinweis "DNS-Abfrage $typ $name fehlgeschlagen: $($_.Exception.Message)"
        @()
    }
}

# Lädt eine ZIP, entpackt sie in einen leeren Ordner und gibt dessen Pfad zurück.
# Den Ordner räumt der Aufrufer weg.
function Get-Paket([string]$url) {
    $tmp = Join-Path $env:TEMP "hgi-paket-$([guid]::NewGuid())"
    New-Item -ItemType Directory -Force "$tmp\entpackt" | Out-Null
    Write-Host "  Lade $url ..."
    Invoke-WebRequest -Uri $url -OutFile "$tmp\paket.zip" -UseBasicParsing
    Expand-Archive -Path "$tmp\paket.zip" -DestinationPath "$tmp\entpackt" -Force
    $tmp
}

# ======================================================================
Schritt "Skripte nach $hgiOrdner ($Modus)"
# ======================================================================

New-Item -ItemType Directory -Force "$hgiOrdner\Logs" | Out-Null
# Nur SYSTEM (S-1-5-18) und Administratoren (S-1-5-32-544). Wichtig, weil SYSTEM die Skripte
# ausführt: Dürfte ein normaler Benutzer sie ändern, liefe sein Code mit vollen Rechten.
# Die Rechte gehören nur auf den Ordner; alles darin erbt sie. Nicht mit /T auf die Dateien setzen:
# Auf Dateien greifen (OI)(CI) nicht, sie bleiben dann ganz ohne Rechte (ab dem zweiten Lauf).
& icacls $hgiOrdner /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' /Q | Out-Null
if ($LASTEXITCODE -ne 0) { Abbruch "Rechte auf $hgiOrdner nicht gesetzt (icacls $LASTEXITCODE)" }
# Was schon im Ordner liegt, wieder auf "erbt vom Ordner" stellen (repariert auch Läufe mit v1.0.0)
if (Get-ChildItem $hgiOrdner -Force) {
    & icacls "$hgiOrdner\*" /reset /T /Q | Out-Null
    if ($LASTEXITCODE -ne 0) { Abbruch "Rechte im Ordner $hgiOrdner nicht zurückgesetzt (icacls $LASTEXITCODE)" }
}

foreach ($datei in 'Zugang.ps1', 'DNS-Eintrag.ps1', 'FMS-Zertifikat-Import.ps1') {
    Copy-Item (Join-Path $PSScriptRoot $datei) $hgiOrdner -Force
}
Ok 'Skripte kopiert, Zugriff nur SYSTEM und Administratoren'

Start-Transcript -Path ("$hgiOrdner\Logs\einrichtung-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date)) | Out-Null
. "$hgiOrdner\Zugang.ps1"

# ======================================================================
Schritt '1Password CLI'
# ======================================================================

$opVersion = $null
if (Test-Path $opExe) { $opVersion = [version]"$(& $opExe --version)".Trim() }
$opNeu = $null
try {
    $opNeu = [version](Invoke-RestMethod -Uri 'https://app-updates.agilebits.com/check/1/0/CLI2/en/2.0.0/N' -TimeoutSec 30).version
} catch {
    Hinweis "1Password-Updateserver nicht erreichbar: $($_.Exception.Message)"
}
if (-not $opNeu -and -not $opVersion) { Abbruch '1Password CLI fehlt und der Updateserver ist nicht erreichbar' }

if ($opNeu -and (-not $opVersion -or $opVersion -lt $opNeu)) {
    $tmp = Get-Paket "https://cache.agilebits.com/dist/1P/op2/pkg/v$opNeu/op_windows_amd64_v$opNeu.zip"
    try {
        # op.exe bekommt das Token, deshalb nur mit gültiger Signatur von AgileBits übernehmen
        $signatur = Get-AuthenticodeSignature "$tmp\entpackt\op.exe"
        if ($signatur.Status -ne 'Valid' -or $signatur.SignerCertificate.Subject -notmatch 'O=Agilebits') {
            Abbruch "op.exe ist nicht gültig von AgileBits signiert ($($signatur.Status), $($signatur.SignerCertificate.Subject))"
        }
        New-Item -ItemType Directory -Force $opOrdner | Out-Null
        Copy-Item "$tmp\entpackt\op.exe" $opOrdner -Force
    } finally {
        Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    }
    Ok "1Password CLI $opNeu installiert"
} else {
    Ok "1Password CLI $opVersion ist aktuell"
}

# ======================================================================
Schritt 'win-acme'
# ======================================================================

$wacsVersion = $null
if (Test-Path $wacs) {
    $wacsVersion = [version]([regex]::Match((Get-Item $wacs).VersionInfo.FileVersion, '^\d+(\.\d+){1,3}').Value)
}
$release = $null
try {
    $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/win-acme/win-acme/releases/latest' -TimeoutSec 30
    $neuVersion = [version]$release.tag_name.TrimStart('v')
} catch {
    Hinweis "GitHub nicht erreichbar, win-acme kann nicht geprüft werden: $($_.Exception.Message)"
}
$wacsVeraltet = $release -and (-not $wacsVersion -or $wacsVersion -lt $neuVersion)

# Eine andere win-acme-Installation (z. B. vom IT-Partner) würde doppelt erneuern.
$fremd = Get-ScheduledTask -TaskName 'win-acme*' -ErrorAction SilentlyContinue |
    Where-Object { ($_.Actions.Execute -join ' ') -notlike "*$WinAcmeOrdner*" }
foreach ($t in $fremd) { Hinweis "Weitere win-acme-Aufgabe: '$($t.TaskName)' -> $($t.Actions.Execute -join ' ')" }

if ($Modus -eq 'Pruefen') {
    # Nur berichten, nichts installieren
    if ($wacsVersion) { Ok "win-acme $wacsVersion in $WinAcmeOrdner" } else { Hinweis "win-acme nicht in $WinAcmeOrdner" }
    if ($wacsVeraltet) { Hinweis "neuere win-acme-Version: $neuVersion" }
} else {
    if ($fremd) { Abbruch 'Erst die weitere win-acme-Installation klären (siehe Hinweis oben)' }
    if (-not $release -and -not $wacsVersion) { Abbruch 'win-acme fehlt und GitHub ist nicht erreichbar' }

    if ($wacsVeraltet) {
        $laeuft = Get-ScheduledTask -TaskName 'win-acme renew*' -ErrorAction SilentlyContinue | Where-Object State -eq 'Running'
        if ($laeuft) { Abbruch 'win-acme läuft gerade (geplante Aufgabe), später erneut versuchen' }

        $paket = $release.assets | Where-Object name -like 'win-acme.v*.x64.trimmed.zip' | Select-Object -First 1
        if (-not $paket) { Abbruch "Kein x64-Paket in Release $($release.tag_name) gefunden" }
        $tmp = Get-Paket $paket.browser_download_url
        try {
            New-Item -ItemType Directory -Force $WinAcmeOrdner | Out-Null
            # Das Paket enthält nur settings_default.json, unsere settings.json bleibt erhalten.
            Copy-Item -Path "$tmp\entpackt\*" -Destination $WinAcmeOrdner -Recurse -Force
        } finally {
            Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
        }
        Ok "win-acme $neuVersion installiert"
    } else {
        Ok "win-acme $wacsVersion ist aktuell"
    }

    # --- settings.json ---
    $settingsDatei = Join-Path $WinAcmeOrdner 'settings.json'
    if (-not (Test-Path $settingsDatei)) {
        Copy-Item (Join-Path $WinAcmeOrdner 'settings_default.json') $settingsDatei
    }
    try {
        $settings = Get-Content $settingsDatei -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Abbruch "settings.json nicht lesbar: $($_.Exception.Message)"
    }

    function Set-Einstellung($abschnitt, [string]$schluessel, $wert) {
        if (-not $settings.PSObject.Properties[$abschnitt]) {
            $settings | Add-Member -NotePropertyName $abschnitt -NotePropertyValue ([pscustomobject]@{})
        }
        $teil = $settings.$abschnitt
        if ($teil.PSObject.Properties[$schluessel]) { $teil.$schluessel = $wert }
        else { $teil | Add-Member -NotePropertyName $schluessel -NotePropertyValue $wert }
    }

    Set-Einstellung 'ScheduledTask' 'StartBoundary' $Uhrzeit
    Set-Einstellung 'ScheduledTask' 'RandomDelay'   '00:15:00'   # Vorgabe 4 h, dann könnte der Neustart um 07:00 kommen
    Set-Einstellung 'Script'        'Timeout'       1800         # Vorgabe 600 s, zu kurz für Schließen + Neustart
    Set-Einstellung 'Validation'    'AllowDnsSubstitution' $true # CNAME folgen, {RecordName} ist dann das Ziel
    if ($SmtpServer) {
        if (-not $SmtpAbsender -or -not $SmtpEmpfaenger) { Abbruch '-SmtpAbsender und -SmtpEmpfaenger gehören zu -SmtpServer' }
        Set-Einstellung 'Notification' 'SmtpServer'        $SmtpServer
        Set-Einstellung 'Notification' 'SmtpPort'          $SmtpPort
        Set-Einstellung 'Notification' 'SenderAddress'     $SmtpAbsender
        Set-Einstellung 'Notification' 'ReceiverAddresses' @($SmtpEmpfaenger)
        Set-Einstellung 'Notification' 'EmailOnSuccess'    $false
    }
    [IO.File]::WriteAllText($settingsDatei, ($settings | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
    Ok "Zeitplan $Uhrzeit (bis 15 Min. später), Skript-Timeout 1800 s$(if ($SmtpServer) { ", Fehlermail an $($SmtpEmpfaenger -join ', ')" })"
    if (-not $SmtpServer) { Hinweis 'Keine Fehlermail eingerichtet (-SmtpServer)' }
}

if ($Modus -eq 'Aktualisieren') { Ende 'Aktualisiert. Zertifikat und Zeitplan unverändert.' }

# ======================================================================
Schritt 'Zugang zu 1Password'
# ======================================================================

$zugangDatei = "$hgiOrdner\zugang.json"
# Ältere zugang.json (Tresor statt Environment) wird wie eine fehlende behandelt.
if ($ZugaengeNeu -or -not (Test-Path $zugangDatei) -or -not (Read-Zugang $zugangDatei).Environment) {
    $token = Read-Host 'Token des 1Password Service Accounts für diesen Kunden' -AsSecureString
    if ($token.Length -eq 0) { Abbruch 'Kein Token eingegeben' }
    $environment = (Read-Host 'ID des 1Password Environments (Developer > Environments > Manage environment)').Trim()
    if ($environment -notmatch '^[a-z0-9]{26}$') { Abbruch "Keine gültige Environment-ID: '$environment'" }
    $klartext = [Net.NetworkCredential]::new('', $token).Password
    try { $werte = Read-1PasswordEnvironment $klartext $environment } catch { Abbruch $_.Exception.Message }
    # Der Service Account eines Kunden soll nur das Environment sehen, keine Tresore.
    $tresore = @(); try { $tresore = Get-1PasswordTresore $klartext } catch { }
    $klartext = $null
    if ($tresore.Count -gt 0) { Abbruch "Der Service Account sieht $($tresore.Count) Tresore ($($tresore.name -join ', ')), erwartet: nur das Environment" }
    $fehlt = 'FMS_DOMAIN', 'FMS_ADMIN_USER', 'FMS_ADMIN_PASSWORD', 'ACME_DNS_URL', 'ACME_DNS_CLIENT', 'ACME_DNS_KEY' |
        Where-Object { -not $werte.$_ }
    $werte = $null
    if ($fehlt) { Abbruch "Im Environment fehlt: $($fehlt -join ', ')" }
    Save-Zugang $zugangDatei @{ Environment = $environment; Token = Protect-Geheimnis $token }
    Ok "Environment $environment, Token verschlüsselt gespeichert"
} else {
    Ok "Environment $((Read-Zugang $zugangDatei).Environment) (gespeichert)"
}

try { $einrichtung = Get-Einrichtung $zugangDatei } catch { Abbruch $_.Exception.Message }
$Domain    = $einrichtung.Domain
$CnameZiel = $einrichtung.CnameZiel
if (-not $Domain) { Abbruch 'FMS_DOMAIN im Environment ist leer' }
Ok "Domain $Domain$(if ($CnameZiel) { ", CNAME-Ziel $CnameZiel" } else { ', ohne CNAME' })"
$name = "FMS $Domain"   # Name der Erneuerung in win-acme

# --- Admin Console ---
if (-not (Test-Path $fmsadmin)) { Abbruch "FileMaker Server nicht gefunden ($fmsadmin)" }
try { $admin = Get-FmsAdmin $zugangDatei } catch { Abbruch $_.Exception.Message }
& $fmsadmin list files -u $admin.Benutzer -p $admin.Passwort | Out-Null
if ($LASTEXITCODE -ne 0) { Abbruch "Anmeldung an der Admin Console mit den Daten aus 1Password fehlgeschlagen (fmsadmin $LASTEXITCODE)" }
Ok "Admin Console: Anmeldung als $($admin.Benutzer)"
$admin = $null

# --- DNS-Dienst (geprüft wird er im Schritt DNS-Kette) ---
try { $dns = Get-DnsZugang $zugangDatei } catch { Abbruch $_.Exception.Message }
if (-not $dns.Url -or -not $dns.Benutzer -or -not $dns.Schluessel) { Abbruch 'DNS-Dienst: ACME_DNS_URL, ACME_DNS_CLIENT oder ACME_DNS_KEY im Environment leer' }
Ok "DNS-Dienst: Client $($dns.Benutzer), $($dns.Url)"
$dns = $null

# ======================================================================
Schritt "DNS beim Kunden - $Domain"
# ======================================================================

# Hierhin schreibt der DNS-Dienst den Prüfwert: das CNAME-Ziel, sonst direkt unter der Domain.
$txtName = if ($CnameZiel) { $CnameZiel } else { "_acme-challenge.$Domain" }
if ($txtName -notlike '_acme-challenge.*') { Abbruch "CNAME-Ziel muss mit _acme-challenge. beginnen ($CnameZiel)" }

$cname = Get-DnsAntwort "_acme-challenge.$Domain" 'CNAME' | Where-Object type -eq 5 | Select-Object -First 1
$cnameIst = if ($cname) { $cname.data.TrimEnd('.') }
if ($CnameZiel) {
    if (-not $cname)              { Abbruch "Kein CNAME für _acme-challenge.$Domain - beim DNS-Anbieter des Kunden eintragen: -> $CnameZiel" }
    if ($cnameIst -ne $CnameZiel) { Abbruch "CNAME zeigt auf $cnameIst statt auf $CnameZiel" }
    Ok "CNAME _acme-challenge.$Domain -> $CnameZiel"
} else {
    if ($cname) { Abbruch "Es gibt einen CNAME _acme-challenge.$Domain -> $cnameIst, dann im Environment als FMS_CNAME_TARGET eintragen" }
    Ok "Kein CNAME, der DNS-Dienst schreibt direkt unter _acme-challenge.$Domain"
}

# --- CAA: darf Let's Encrypt ausstellen? ---
# Von der Domain aufwärts (fm.kunde.at, kunde.at). Die erste Ebene mit CAA-Einträgen entscheidet.
# Manche Antworten kommen als Hex ("\# 22 00 05 69 73 73 75 65 ..."), deshalb auch Hex vergleichen.
$teile = $Domain.Split('.')
$caaGeprueft = $false
for ($i = 0; $i -le $teile.Count - 2 -and -not $caaGeprueft; $i++) {
    $ebene = $teile[$i..($teile.Count - 1)] -join '.'
    $caa = Get-DnsAntwort $ebene 'CAA' | Where-Object type -eq 257
    if (-not $caa) { continue }
    $caaGeprueft = $true
    $flach = $caa | ForEach-Object { ($_.data -replace '\s', '').ToLower() }
    $issue = $flach | Where-Object { $_ -match 'issue' -or $_ -match '6973737565' }   # 'issue' in Hex
    if (-not $issue) {
        Ok "CAA auf $ebene ohne Einschränkung der Aussteller"
    } elseif ($issue | Where-Object { $_ -match 'letsencrypt\.org' -or $_ -match '6c657473656e63727970742e6f7267' }) {
        Ok "CAA auf $ebene erlaubt Let's Encrypt"
    } else {
        Abbruch "CAA auf $ebene erlaubt Let's Encrypt nicht: $($caa.data -join ' | ') - 'letsencrypt.org' ergänzen lassen"
    }
}
if (-not $caaGeprueft) { Ok 'Kein CAA-Eintrag, alle Aussteller erlaubt' }

if ($Modus -eq 'Pruefen') { Ende 'Prüfung abgeschlossen. An FileMaker Server und win-acme wurde nichts geändert.' }

if (-not $AcmeEmail) { Abbruch 'Adresse für das Let''s-Encrypt-Konto fehlt (-AcmeEmail bzw. Vorgabe im Skript)' }

# ======================================================================
Schritt 'DNS-Kette testen (ohne Let''s Encrypt)'
# ======================================================================
# Ein Zufallswert geht über den DNS-Dienst nach Cloudflare und muss dann unter
# _acme-challenge.<Domain> sichtbar werden, gegebenenfalls über den CNAME des Kunden.
# Danach wird er wieder entfernt.

$zufall = New-Object byte[] 32
[Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($zufall)
$testwert = [Convert]::ToBase64String($zufall).TrimEnd('=').Replace('+', '-').Replace('/', '_')   # 43 Zeichen wie bei ACME

& "$hgiOrdner\DNS-Eintrag.ps1" create $txtName $testwert | Out-Null
if ($LASTEXITCODE -ne 0) { Abbruch "DNS-Dienst hat den Eintrag abgelehnt, siehe $hgiOrdner\Logs\dns-eintrag.log" }

$gefunden = $false
$bis = (Get-Date).AddMinutes(2)
while (-not $gefunden -and (Get-Date) -lt $bis) {
    Start-Sleep -Seconds 10
    $txt = Get-DnsAntwort "_acme-challenge.$Domain" 'TXT' | Where-Object type -eq 16
    $gefunden = [bool]($txt | Where-Object { $_.data.Trim('"') -eq $testwert })
}
& "$hgiOrdner\DNS-Eintrag.ps1" delete $txtName $testwert | Out-Null
if (-not $gefunden) { Abbruch "Testwert nach 2 Min. nicht unter _acme-challenge.$Domain sichtbar" }
Ok "Testwert kommt über den DNS-Dienst an ($txtName), wieder entfernt"

# Argumente, die Staging und Produktiv gemeinsam haben
$wacsBasis = @(
    '--source', 'manual', '--host', $Domain,
    '--validationmode', 'dns-01', '--validation', 'script',
    '--dnsscript', "$hgiOrdner\DNS-Eintrag.ps1",
    '--dnscreatescriptarguments', 'create {RecordName} {Token}',
    '--dnsdeletescriptarguments', 'delete {RecordName} {Token}',
    '--store', 'pemfiles', '--pemfilesname', 'fms',
    '--accepttos', '--emailaddress', $AcmeEmail
)

# ======================================================================
if ($Modus -eq 'Staging') {
    Schritt 'Test-Zertifikat von Let''s Encrypt (Staging)'
# ======================================================================
    $pem = "$hgiOrdner\pem-staging"
    & $wacs @wacsBasis --friendlyname "$name (Staging)" --pemfilespath $pem `
        --baseuri $stagingUri --installation none --notaskscheduler
    $rc = $LASTEXITCODE
    # Die Staging-Erneuerung wird nicht gebraucht, sonst würde win-acme sie weiter erneuern.
    & $wacs --cancel --friendlyname "$name (Staging)" --baseuri $stagingUri | Out-Null
    if ($rc -ne 0 -or -not (Test-Path "$pem\fms-crt.pem")) { Abbruch "win-acme meldet einen Fehler ($rc), siehe Ausgabe oben" }
    Ok 'Test-Zertifikat erhalten, DNS-01-Prüfung funktioniert'

    Schritt 'Import-Skript als Dry-Run (mit dem Test-Zertifikat)'
    & "$hgiOrdner\FMS-Zertifikat-Import.ps1" -DryRun -Domain $Domain `
        -CertFile "$pem\fms-crt.pem" -KeyFile "$pem\fms-key.pem" -ChainFile "$pem\fms-chain-only.pem"
    if ($LASTEXITCODE -ne 0) { Abbruch "Dry-Run des Import-Skripts fehlgeschlagen (Exit-Code $LASTEXITCODE)" }
    Ok 'Import-Skript: Dateien, Schlüssel, Domain und Admin-Zugang in Ordnung'

    Remove-Item -Recurse -Force $pem
    Ende 'Staging erfolgreich. Nächster Schritt: Produktiv in einem Wartungsfenster.'
}

# ======================================================================
Schritt 'Zertifikat von Let''s Encrypt (produktiv)'
# ======================================================================

$pem = "$hgiOrdner\pem"
$renewalOrdner = Join-Path $env:ProgramData 'win-acme\acme-v02.api.letsencrypt.org'
$vorhanden = Get-ChildItem "$renewalOrdner\*.renewal.json" -ErrorAction SilentlyContinue |
    Where-Object { (Get-Content $_.FullName -Raw) -match [regex]::Escape($Domain) }
if ($vorhanden -and -not $ErneuerungNeu) {
    Abbruch "Für $Domain gibt es schon eine Erneuerung ($($vorhanden.Name -join ', ')). Ersetzen mit -ErneuerungNeu."
}

if (-not $Ja) {
    Write-Host "`n  Der produktive Lauf importiert das Zertifikat SOFORT: Die Datenbanken werden geschlossen" -ForegroundColor Yellow
    Write-Host "  (Clients 60 s vorher gewarnt) und FileMaker Server startet neu." -ForegroundColor Yellow
    if ((Read-Host '  Fortfahren? JA eingeben') -cne 'JA') { Abbruch 'Vom Benutzer abgebrochen' }
}

if ($vorhanden) {
    & $wacs --cancel --friendlyname $name --baseuri $prodUri | Out-Null
    Ok 'Bisherige Erneuerung entfernt'
}

$start = Get-Date
& $wacs @wacsBasis --friendlyname $name --pemfilespath $pem --baseuri $prodUri `
    --installation script --script "$hgiOrdner\FMS-Zertifikat-Import.ps1" `
    --scriptparameters "-CertFile '$pem\fms-crt.pem' -KeyFile '$pem\fms-key.pem' -ChainFile '$pem\fms-chain-only.pem' -Domain '$Domain'"
$rc = $LASTEXITCODE
if ($rc -ne 0 -or -not (Test-Path "$pem\fms-crt.pem") -or (Get-Item "$pem\fms-crt.pem").LastWriteTime -lt $start) {
    Abbruch "win-acme meldet einen Fehler ($rc). Import-Log: $hgiOrdner\Logs\fms-zertifikat.log"
}
Ok 'Zertifikat ausgestellt und importiert'

# ======================================================================
Schritt 'Geplante Aufgabe prüfen'
# ======================================================================

function Get-RenewTask { Get-ScheduledTask -TaskName 'win-acme renew (acme-v02*' -ErrorAction SilentlyContinue | Select-Object -First 1 }
function Test-Uhrzeit($task) { $task -and ([datetime]$task.Triggers[0].StartBoundary).TimeOfDay -eq [timespan]$Uhrzeit }

$task = Get-RenewTask
if (-not (Test-Uhrzeit $task)) {
    # Bestehende Aufgabe mit alter Uhrzeit: nach den neuen Einstellungen neu anlegen lassen
    & $wacs --setuptaskscheduler | Out-Null
    $task = Get-RenewTask
}
if (-not $task)               { Abbruch 'Keine geplante Aufgabe von win-acme gefunden' }
if (-not (Test-Uhrzeit $task)) { Abbruch "Geplante Aufgabe startet um $($task.Triggers[0].StartBoundary) statt $Uhrzeit" }
Ok "'$($task.TaskName)' täglich $Uhrzeit als $($task.Principal.UserId)"

Ende 'Einrichtung abgeschlossen. Kunde in die Kundenliste eintragen.'

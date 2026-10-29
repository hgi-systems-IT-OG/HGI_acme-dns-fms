<#
  FMS-Zertifikat-Import.ps1  (hgi systems)

  Wird nach einer erfolgreichen Erneuerung aufgerufen (z. B. als Installationsschritt von win-acme).
  Ablauf:
    1. Prüfen     Dateien vorhanden, Schlüssel passt zum Zertifikat, Domain im Zertifikat, nicht abgelaufen
    2. Import     fmsadmin certificate import
    3. Schließen  fmsadmin close mit Vorwarnung an die Clients
    4. Warten     bis ALLE Datenbanken zu sind (fmsadmin list files), mit Timeout
    5. Neustart   Windows-Dienst "FileMaker Server" - nur wenn 2. bis 4. erfolgreich waren
    6. Prüfen     Dienst läuft, Datenbanken offen, Server liefert das neue Zertifikat aus

  Schlägt etwas vor dem Neustart fehl, wird NICHT neu gestartet. Wurden die Datenbanken schon
  geschlossen, werden sie wieder geöffnet.

  -DryRun prüft nur (Dateien, Schlüssel, Zugang zu fmsadmin, offene Datenbanken) und ändert nichts.

  Exit-Codes:
     0  OK
    10  Datei fehlt                     11  Schlüssel passt nicht zum Zertifikat
    12  Domain nicht im Zertifikat      13  Zertifikat abgelaufen / läuft binnen 24 h ab
    14  fmsadmin-Zugang fehlgeschlagen
    20  Import fehlgeschlagen           (kein Neustart)
    30  Schließen nicht bestätigt       (kein Neustart, Datenbanken wieder geöffnet)
    40  Dienst-Neustart fehlgeschlagen
    50  Server nach Neustart nicht erreichbar oder Datenbanken nicht offen
    51  Server liefert nicht das neue Zertifikat aus

  Zugangsdaten der Admin Console: liegen im 1Password-Environment des Kunden und werden bei jedem Lauf
  frisch gelesen, siehe Zugang.ps1. Ist 1Password nicht erreichbar, endet der Lauf mit 14, bevor
  irgendetwas geändert wird.
  Hinweis: fmsadmin bekommt das Passwort per -p übergeben und ist damit während des Laufs in der
  Prozessliste sichtbar.

  win-acme bricht Skripte nach Script.Timeout ab (Vorgabe 600 s). Das Einrichtungsskript setzt
  ihn auf 1800 s, weil Schließen + Neustart + Warten länger als 10 Minuten dauern können.
#>
param(
    [Parameter(Mandatory)] [string]$CertFile,    # Zertifikat (nur das Server-Zertifikat, PEM)
    [Parameter(Mandatory)] [string]$KeyFile,     # privater Schlüssel (PEM, unverschlüsselt)
    [Parameter(Mandatory)] [string]$ChainFile,   # nur die Zwischenzertifikate (PEM)
    [Parameter(Mandatory)] [string]$Domain,
    [string]$ZugangDatei     = 'C:\ProgramData\hgi\Zertifikat\zugang.json',
    [int]   $CloseWarnSec    = 60,   # Vorwarnzeit für verbundene Clients
    [int]   $CloseTimeoutMin = 5,    # so lange zusätzlich warten, bis alle Datenbanken zu sind
    [int]   $StartTimeoutMin = 5,    # so lange nach dem Neustart auf fmsadmin warten
    [string]$LogFile         = 'C:\ProgramData\hgi\Zertifikat\Logs\fms-zertifikat.log',
    [switch]$DryRun
)

. "$PSScriptRoot\Zugang.ps1"

$fmsDir = 'C:\Program Files\FileMaker\FileMaker Server\Database Server'
$fms    = Join-Path $fmsDir 'fmsadmin.exe'
$ossl   = Join-Path $fmsDir 'openssl.exe'
$svc    = 'FileMaker Server'

function Log([string]$msg) {
    $line = '{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $msg
    Write-Output $line
    New-Item -ItemType Directory -Force (Split-Path $LogFile) | Out-Null
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
}

function Fail([string]$msg, [int]$code) {
    Log "FEHLER ($code): $msg"
    # TODO: Benachrichtigung anbinden (Mail, Monitoring, ...)
    exit $code
}

# --- Admin-Console-Zugang ---
try {
    $admin   = Get-FmsAdmin $ZugangDatei
    $admUser = $admin.Benutzer
    $admPw   = $admin.Passwort
} catch {
    Fail "Zugangsdaten nicht lesbar ($($_.Exception.Message))" 14
}

function Invoke-Fms { & $fms @args -u $admUser -p $admPw }
function Get-OpenFiles { @(Invoke-Fms list files 2>$null) -match '\.fmp12' }

Log "===== Start$(if ($DryRun) { ' (DRY-RUN)' }) - $Domain ====="

# ===== 1. Prüfen =====
foreach ($f in $CertFile, $KeyFile, $ChainFile) {
    if (-not (Test-Path $f)) { Fail "Datei fehlt: $f" 10 }
}

$pubCert = (& $ossl x509 -in $CertFile -noout -pubkey 2>$null) -join ''
$pubKey  = (& $ossl pkey -in $KeyFile -pubout 2>$null) -join ''
if (-not $pubCert -or $pubCert -ne $pubKey) { Fail 'Schlüssel passt nicht zum Zertifikat' 11 }

$san = (& $ossl x509 -in $CertFile -noout -ext subjectAltName 2>$null) -join ' '
if ($san -notmatch ('DNS:' + [regex]::Escape($Domain) + '(\s|,|$)')) { Fail "Domain $Domain nicht im Zertifikat ($san)" 12 }

& $ossl x509 -in $CertFile -noout -checkend 86400 | Out-Null
if ($LASTEXITCODE -ne 0) { Fail 'Zertifikat ist abgelaufen oder läuft binnen 24 h ab' 13 }
Log ("Zertifikat OK: " + ((& $ossl x509 -in $CertFile -noout -subject -enddate) -join ', '))

$open = Get-OpenFiles
if ($LASTEXITCODE -ne 0) { Fail 'fmsadmin-Zugang fehlgeschlagen (Benutzer/Passwort?)' 14 }
Log "Offene Datenbanken: $($open.Count)"

if ($DryRun) {
    Log "DRY-RUN: würde importieren, $($open.Count) Datenbank(en) schließen (Vorwarnung $CloseWarnSec s), auf das Schließen warten und '$svc' neu starten."
    Log '===== Ende (DRY-RUN, nichts geändert) ====='
    exit 0
}

# ===== 2. Import =====
$out = Invoke-Fms certificate import $CertFile --keyfile $KeyFile --intermediateCA $ChainFile -y 2>&1
$rc  = $LASTEXITCODE
Log ("fmsadmin certificate import: " + (($out | ForEach-Object { "$_" }) -join ' | '))
if ($rc -ne 0) { Fail "Import fehlgeschlagen (ExitCode $rc) - KEIN Neustart" 20 }

# ===== 3. Datenbanken schließen =====
Log "Schließe Datenbanken, Vorwarnung $CloseWarnSec s"
Invoke-Fms close -y -t $CloseWarnSec -m "Wartung: Der Server startet in $CloseWarnSec Sekunden kurz neu." | Out-Null

# ===== 4. Warten, bis ALLE zu sind =====
# Eine leere Liste zählt nur, wenn fmsadmin sie ohne Fehler geliefert hat. Schlägt die Abfrage
# fehl, ist nichts bestätigt und es wird weiter gewartet.
$deadline = (Get-Date).AddSeconds($CloseWarnSec).AddMinutes($CloseTimeoutMin)
do {
    Start-Sleep -Seconds 10
    $open      = Get-OpenFiles
    $abfrageOk = $LASTEXITCODE -eq 0
    if ($abfrageOk) { Log "Noch offen: $($open.Count)" }
    else            { Log "Abfrage der offenen Datenbanken fehlgeschlagen (ExitCode $LASTEXITCODE) - zählt als noch offen" }
} while ((-not $abfrageOk -or $open.Count -gt 0) -and (Get-Date) -lt $deadline)

if (-not $abfrageOk -or $open.Count -gt 0) {
    Log 'Timeout - öffne alle Datenbanken wieder'
    Invoke-Fms open -y | Out-Null
    $grund = if ($abfrageOk) { 'Datenbanken nicht geschlossen: ' + ($open -join ', ') } else { 'Schließen nicht bestätigt (fmsadmin list files fehlgeschlagen)' }
    Fail "$grund - KEIN Neustart. Zertifikat ist importiert, aber erst nach einem Neustart aktiv." 30
}

# ===== 5. Dienst neu starten =====
Log "Alle Datenbanken geschlossen - starte '$svc' neu"
try {
    Restart-Service -Name $svc -ErrorAction Stop -WarningAction SilentlyContinue
} catch {
    Fail "Neustart fehlgeschlagen: $($_.Exception.Message)" 40
}

# ===== 6. Prüfen =====
$deadline = (Get-Date).AddMinutes($StartTimeoutMin)
do {
    Start-Sleep -Seconds 10
    Invoke-Fms list files 2>$null | Out-Null
} while ($LASTEXITCODE -ne 0 -and (Get-Date) -lt $deadline)
if ($LASTEXITCODE -ne 0) { Fail "fmsadmin antwortet $StartTimeoutMin Min. nach dem Neustart nicht" 50 }

$open = Get-OpenFiles
if ($open.Count -eq 0) {
    Log 'Keine Datenbank offen - öffne alle'
    Invoke-Fms open -y | Out-Null
    Start-Sleep -Seconds 15
    $open = Get-OpenFiles
}
if ($open.Count -eq 0) { Fail 'Nach dem Neustart ist keine Datenbank offen' 50 }
Log "Offene Datenbanken: $($open.Count)"

$served = ($null | & $ossl s_client -connect 127.0.0.1:443 -servername $Domain 2>$null | & $ossl x509 -noout -pubkey 2>$null) -join ''
if ($served -ne $pubCert) { Fail 'Server liefert auf 443 nicht das neue Zertifikat aus' 51 }
Log 'Server liefert das neue Zertifikat aus'

Log '===== Ende OK ====='
exit 0

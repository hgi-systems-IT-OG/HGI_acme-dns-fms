<#
  Zugang.ps1  (hgi systems)

  Gemeinsame Funktionen für die Zugänge. Wird von den anderen Skripten per
  ". $PSScriptRoot\Zugang.ps1" eingebunden.

  Alles Kundenspezifische liegt in 1Password, ein Environment pro Kunde (z. B. "6819 (Willi GmbH)"):
      FMS_DOMAIN           Domain des FileMaker Servers, z. B. fm.kunde.at
      FMS_CNAME_TARGET     Ziel des CNAME _acme-challenge.<FMS_DOMAIN> (leer, wenn die Domain selbst
                           in der Cloudflare-Zone von hgi liegt)
      FMS_ADMIN_USER       Benutzer / Passwort der Admin Console von FileMaker Server
      FMS_ADMIN_PASSWORD
      ACME_DNS_URL         URL des hgi-DNS-Dienstes
      ACME_DNS_CLIENT      Clientname / Schlüssel beim DNS-Dienst
      ACME_DNS_KEY
  Gelesen wird mit der 1Password CLI (op run --environment) über einen Service Account, der NUR
  dieses Environment sieht.

  Auf dem Server liegt nur zugang.json mit der ID des Environments und dem Token des Service
  Accounts. Das Token ist per DPAPI im Maschinen-Bereich verschlüsselt: Entschlüsseln kann es nur
  ein Prozess auf DIESEM Server. Lesen dürfen die Datei nur SYSTEM und die Administratoren
  (Ordnerrechte setzt das Einrichtungsskript).
#>

Add-Type -AssemblyName System.Security

$opExe              = 'C:\Program Files\1Password CLI\op.exe'
$ZugangDateiVorgabe = 'C:\ProgramData\hgi\Zertifikat\zugang.json'

function Protect-Geheimnis([Security.SecureString]$Geheimnis) {
    $klartext = [Net.NetworkCredential]::new('', $Geheimnis).Password
    $bytes    = [Text.Encoding]::UTF8.GetBytes($klartext)
    $schutz   = [Security.Cryptography.ProtectedData]::Protect($bytes, $null, 'LocalMachine')
    [Convert]::ToBase64String($schutz)
}

function Unprotect-Geheimnis([string]$Verschluesselt) {
    $bytes = [Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($Verschluesselt), $null, 'LocalMachine')
    [Text.Encoding]::UTF8.GetString($bytes)
}

function Save-Zugang([string]$Pfad, [hashtable]$Daten) {
    New-Item -ItemType Directory -Force (Split-Path $Pfad) | Out-Null
    $Daten | ConvertTo-Json | Set-Content -Path $Pfad -Encoding UTF8
}

function Read-Zugang([string]$Pfad = $ZugangDateiVorgabe) {
    Get-Content -Path $Pfad -Raw -Encoding UTF8 | ConvertFrom-Json
}

# Ruft op.exe mit dem Token auf. Das Token steht nur während des Aufrufs in der Umgebung
# dieses Prozesses. Liefert die Ausgabe von op als Text, bei Fehlern eine Ausnahme mit dessen Meldung.
function Invoke-1Password([string]$Token, [string[]]$Argumente) {
    $ErrorActionPreference = 'Continue'   # Fehlertext von op.exe selbst auswerten, nicht abbrechen
    $env:OP_SERVICE_ACCOUNT_TOKEN = $Token
    try {
        $ausgabe = & $opExe @Argumente 2>&1
        $rc = $LASTEXITCODE
    } finally {
        Remove-Item Env:\OP_SERVICE_ACCOUNT_TOKEN -ErrorAction SilentlyContinue
    }
    if ($rc -ne 0) { throw "1Password (op $($Argumente[0..1] -join ' ')): $($ausgabe -join ' ')" }
    ($ausgabe | Where-Object { $_ -is [string] }) -join "`n"
}

# Die Tresore, die ein Token sehen darf. Der Service Account eines Kunden braucht keinen.
function Get-1PasswordTresore([string]$Token) {
    @(Invoke-1Password $Token @('vault', 'list', '--format', 'json') | ConvertFrom-Json)
}

# Alle FMS_*- und ACME_*-Variablen eines Environments als Objekt. op run startet dafür eine
# PowerShell, die sie als JSON ausgibt; --no-masking, weil die Werte hier gebraucht werden.
# Sie landen nur in der Variablen des Aufrufers, nicht in Ausgabe oder Log.
function Read-1PasswordEnvironment([string]$Token, [string]$Environment) {
    $ausgeben = '$v = @{}; Get-ChildItem env: | Where-Object Name -match ''^(FMS|ACME)_'' | ForEach-Object { $v[$_.Name] = $_.Value }; $v | ConvertTo-Json -Compress'
    Invoke-1Password $Token @('run', '--environment', $Environment, '--no-masking', '--',
        'powershell.exe', '-NoProfile', '-NonInteractive', '-Command', $ausgeben) | ConvertFrom-Json
}

function Get-1PasswordEnvironment([string]$Pfad = $ZugangDateiVorgabe) {
    $zugang = Read-Zugang $Pfad
    Read-1PasswordEnvironment (Unprotect-Geheimnis $zugang.Token) $zugang.Environment
}

function Get-Einrichtung([string]$Pfad = $ZugangDateiVorgabe) {
    $e = Get-1PasswordEnvironment $Pfad
    [pscustomobject]@{
        Domain    = $e.FMS_DOMAIN
        CnameZiel = $e.FMS_CNAME_TARGET
    }
}

function Get-FmsAdmin([string]$Pfad = $ZugangDateiVorgabe) {
    $e = Get-1PasswordEnvironment $Pfad
    [pscustomobject]@{
        Benutzer = $e.FMS_ADMIN_USER
        Passwort = $e.FMS_ADMIN_PASSWORD
    }
}

function Get-DnsZugang([string]$Pfad = $ZugangDateiVorgabe) {
    $e = Get-1PasswordEnvironment $Pfad
    [pscustomobject]@{
        Url        = $e.ACME_DNS_URL
        Benutzer   = $e.ACME_DNS_CLIENT
        Schluessel = $e.ACME_DNS_KEY
    }
}

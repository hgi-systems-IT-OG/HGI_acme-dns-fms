<#
  DNS-Eintrag.ps1  (hgi systems)

  Wird von win-acme bei jeder Erneuerung aufgerufen (DNS-01-Prüfung):
      create  -> den Prüfwert von Let's Encrypt über den hgi-DNS-Dienst als TXT-Eintrag anlegen
      delete  -> den TXT-Eintrag nach der Prüfung wieder entfernen

  Der Dienst (Repo HGI_acme-dns) spricht das lego-"httpreq"-Protokoll:
      POST <Url>/present   bzw.  /cleanup   { "fqdn": "_acme-challenge.<name>.", "value": "<Prüfwert>" }
  mit Basic Auth (Clientname + Schlüssel). Er schreibt den Eintrag in die Cloudflare-Zone und
  erlaubt pro Client nur die Namen, die für ihn hinterlegt sind.

  Hat der Kunde einen CNAME  _acme-challenge.<fm-domain> -> _acme-challenge.fm-kunde.<hgi-zone>,
  übergibt win-acme in {RecordName} schon das Ziel des CNAME.

  Exit-Codes: 0 OK, 1 Fehler (win-acme bricht die Erneuerung dann ab)
#>
param(
    [Parameter(Mandatory, Position = 0)] [ValidateSet('create', 'delete')] [string]$Aktion,
    [Parameter(Mandatory, Position = 1)] [string]$RecordName,
    [Parameter(Mandatory, Position = 2)] [string]$Token,
    [string]$ZugangDatei = 'C:\ProgramData\hgi\Zertifikat\zugang.json',
    [string]$LogFile     = 'C:\ProgramData\hgi\Zertifikat\Logs\dns-eintrag.log'
)

. "$PSScriptRoot\Zugang.ps1"

function Log([string]$msg) {
    $line = '{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $msg
    Write-Output $line
    New-Item -ItemType Directory -Force (Split-Path $LogFile) | Out-Null
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
}

$pfad = @{ create = 'present'; delete = 'cleanup' }[$Aktion]

try {
    $zugang = Get-DnsZugang $ZugangDatei   # Clientname und Schlüssel aus 1Password
    $basic  = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$($zugang.Benutzer):$($zugang.Schluessel)"))
    $inhalt = @{ fqdn = $RecordName.TrimEnd('.') + '.'; value = $Token.Trim('"') } | ConvertTo-Json

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-RestMethod -Method Post -Uri "$($zugang.Url.TrimEnd('/'))/$pfad" -Headers @{ Authorization = "Basic $basic" } `
        -Body $inhalt -ContentType 'application/json' -TimeoutSec 60 | Out-Null

    Log "$pfad $RecordName OK"
    exit 0
} catch {
    Log "FEHLER $pfad $RecordName : $($_.Exception.Message)"
    exit 1
}

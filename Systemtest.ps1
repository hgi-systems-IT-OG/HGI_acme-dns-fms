<#
  Systemtest.ps1  (hgi systems)

  Ruft dieselben Skripte auf wie win-acme bei einer Erneuerung, ohne etwas zu ändern:
  Zugänge aus 1Password lesen, Prüfwert über den DNS-Dienst setzen und wieder entfernen,
  Import-Skript als Dry-Run. Gedacht für einen Lauf als SYSTEM, denn so läuft die geplante
  Aufgabe von win-acme. Das Einrichtungsskript startet es im Modus Staging über eine kurzlebige
  geplante Aufgabe.

  Ergebnis: Logs\systemtest.json mit dem Exit-Code jedes Schritts (0 = OK).
#>
param(
    [string]$Pem = "$PSScriptRoot\pem"   # Ordner mit fms-crt.pem, fms-key.pem, fms-chain-only.pem
)

$ergebnis = [ordered]@{
    AlsSystem    = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq 'S-1-5-18'
    DnsAnlegen   = $null
    DnsEntfernen = $null
    ImportDryRun = $null
    Fehler       = ''
}
try {
    . "$PSScriptRoot\Zugang.ps1"
    $einrichtung = Get-Einrichtung
    # Wie im Einrichtungsskript: das CNAME-Ziel, sonst direkt unter der Domain
    $txtName = if ($einrichtung.CnameZiel) { $einrichtung.CnameZiel } else { "_acme-challenge.$($einrichtung.Domain)" }

    & "$PSScriptRoot\DNS-Eintrag.ps1" create $txtName systemtest | Out-Null
    $ergebnis.DnsAnlegen = $LASTEXITCODE
    & "$PSScriptRoot\DNS-Eintrag.ps1" delete $txtName systemtest | Out-Null
    $ergebnis.DnsEntfernen = $LASTEXITCODE

    & "$PSScriptRoot\FMS-Zertifikat-Import.ps1" -DryRun -Domain $einrichtung.Domain `
        -CertFile "$Pem\fms-crt.pem" -KeyFile "$Pem\fms-key.pem" -ChainFile "$Pem\fms-chain-only.pem" | Out-Null
    $ergebnis.ImportDryRun = $LASTEXITCODE
} catch {
    $ergebnis.Fehler = $_.Exception.Message
}
$ergebnis | ConvertTo-Json | Set-Content "$PSScriptRoot\Logs\systemtest.json" -Encoding UTF8

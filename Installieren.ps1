<#
  Installieren.ps1  (hgi systems)

  Einstieg mit einem Befehl, in einer PowerShell als Administrator:

    [Net.ServicePointManager]::SecurityProtocol='Tls12'; irm https://github.com/hgi-systems-IT-OG/HGI_acme-dns-fms/releases/latest/download/Installieren.ps1 | iex

  Fragt nach dem Modus, laedt das neueste Paket aus demselben Release, prueft die Pruefsumme und
  startet Einrichten-FMS-Zertifikat.ps1. Beim ersten Lauf fragt das noch nach dem Token des
  1Password Service Accounts und der ID des Environments, alles andere kommt aus 1Password.

  Eine bestimmte Version statt der neuesten: in der URL "latest/download" durch
  "download/<tag>" ersetzen.

  Kein "exit" in diesem Skript: Ueber "irm | iex" wuerde das die ganze PowerShell schliessen.
#>

function Reset-HgiKonsole {
    # Programme wie win-acme oder die 1Password CLI koennen in der Konsole den Modus
    # DISABLE_NEWLINE_AUTO_RETURN (0x8) stehen lassen. Dann springt eine neue Zeile nicht mehr an
    # den Zeilenanfang, und Menue und Ausgabe erscheinen treppenartig verschoben.
    try {
        if (-not ('Hgi.Konsole' -as [type])) {
            Add-Type -Namespace Hgi -Name Konsole -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int nStdHandle);
[DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr h, out uint m);
[DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr h, uint m);
'@
        }
        $h = [Hgi.Konsole]::GetStdHandle(-11)
        $m = [uint32]0
        if ([Hgi.Konsole]::GetConsoleMode($h, [ref]$m) -and ($m -band 8)) {
            [Hgi.Konsole]::SetConsoleMode($h, [uint32]($m - 8)) | Out-Null
        }
    } catch { }
}

function Install-HgiFmsZertifikat {
    $repo   = 'hgi-systems-IT-OG/HGI_acme-dns-fms'
    $basis  = "https://github.com/$repo/releases/latest/download"
    $paket  = 'HGI_acme-dns-fms.zip'

    $ErrorActionPreference = 'Stop'
    $ProgressPreference    = 'SilentlyContinue'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $admin) {
        Write-Host 'Bitte PowerShell als Administrator starten.' -ForegroundColor Red
        return
    }

    Reset-HgiKonsole
    Write-Host "`nFileMaker Server: Zertifikat ueber Let's Encrypt (hgi systems)`n" -ForegroundColor Cyan
    Write-Host '  1  Pruefen        nichts an FileMaker Server aendern, nur pruefen'
    Write-Host '  2  Staging        alles einrichten, Test-Zertifikat, kein Neustart'
    Write-Host '  3  Produktiv      echtes Zertifikat, FileMaker Server startet SOFORT neu'
    Write-Host '  4  Aktualisieren  nur Skripte, win-acme und 1Password CLI erneuern'
    $modus = @{ '1' = 'Pruefen'; '2' = 'Staging'; '3' = 'Produktiv'; '4' = 'Aktualisieren' }[(Read-Host "`nModus (1-4)").Trim()]
    if (-not $modus) {
        Write-Host 'Abgebrochen.' -ForegroundColor Red
        return
    }

    $tmp = Join-Path $env:TEMP "hgi-fms-zertifikat-$([guid]::NewGuid())"
    New-Item -ItemType Directory -Force "$tmp\entpackt" | Out-Null
    try {
        Write-Host "`nLade $basis/$paket ..."
        Invoke-WebRequest -Uri "$basis/$paket"        -OutFile "$tmp\$paket"        -UseBasicParsing
        Invoke-WebRequest -Uri "$basis/$paket.sha256" -OutFile "$tmp\$paket.sha256" -UseBasicParsing

        $soll = ((Get-Content "$tmp\$paket.sha256" -Raw).Trim() -split '\s+')[0]
        $ist  = (Get-FileHash "$tmp\$paket" -Algorithm SHA256).Hash
        if ($ist -ne $soll) {
            Write-Host "Pruefsumme stimmt nicht ($ist statt $soll). Abgebrochen." -ForegroundColor Red
            return
        }
        Expand-Archive -Path "$tmp\$paket" -DestinationPath "$tmp\entpackt" -Force

        # Gilt nur fuer diesen Prozess: Die heruntergeladenen Skripte sind nicht signiert.
        Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
        & "$tmp\entpackt\Einrichten-FMS-Zertifikat.ps1" -Modus $modus
    } finally {
        Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
        Reset-HgiKonsole
    }
}

Install-HgiFmsZertifikat

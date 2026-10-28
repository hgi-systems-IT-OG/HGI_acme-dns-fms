# HGI_acme-dns-fms

SSL-Zertifikate von Let's Encrypt für FileMaker Server unter Windows, automatisch erneuert über die DNS-01-Prüfung. Am Server muss dafür kein Port geöffnet werden.

> Dieses Repo wird aus dem internen Repo `HGI_acme-dns` (Ordner `fms-windows/`) veröffentlicht. Änderungen bitte dort.

## Einrichtung

In einer PowerShell **als Administrator** auf dem FileMaker Server:

```powershell
[Net.ServicePointManager]::SecurityProtocol='Tls12'; irm https://github.com/hgi-systems-IT-OG/HGI_acme-dns-fms/releases/latest/download/Installieren.ps1 | iex
```

Das Skript fragt nach dem Modus und beim ersten Lauf nach dem Token des 1Password Service Accounts und der ID des Environments. Alles andere liest es aus 1Password.

| Modus | Was passiert |
|---|---|
| 1 Pruefen | Prüft 1Password, Anmeldung an der Admin Console, CNAME, CAA, Versionen. Legt nur `C:\ProgramData\hgi\Zertifikat` mit `zugang.json` an und installiert die 1Password CLI. An FileMaker Server und win-acme ändert sich nichts. |
| 2 Staging | Richtet alles ein und holt ein **Test**-Zertifikat. Kein Import, kein Neustart, kein Zeitplan. |
| 3 Produktiv | Holt das echte Zertifikat, **schließt die Datenbanken und startet FileMaker Server sofort neu**, legt den Zeitplan an. Nur im Wartungsfenster. |
| 4 Aktualisieren | Bringt Skripte, win-acme und 1Password CLI auf den neuesten Stand. Kein neues Zertifikat, kein Neustart. |

Danach erneuert die geplante Aufgabe von win-acme täglich um 03:00, wenn das Zertifikat fällig ist, und startet FileMaker Server dabei kurz neu.

## Vorbereitung pro Server

1. **DNS-Dienst von hgi:** einen Client für diesen Server anlegen, der das CNAME-Ziel ohne `_acme-challenge.` (z. B. `fm-kunde.<zone>`) beschreiben darf.
2. **DNS beim Kunden:** `_acme-challenge.fm.kunde.at  CNAME  _acme-challenge.fm-kunde.<zone>`.
   Das Ziel muss mit `_acme-challenge.` beginnen. Liegt die Domain selbst in der Cloudflare-Zone von hgi, entfällt der CNAME.
3. **1Password:** ein Environment nur für diesen Kunden (Developer → Environments), z. B. `6819 (Willi GmbH)`, mit diesen Variablen:

   | Variable | Inhalt |
   |---|---|
   | `FMS_DOMAIN` | Domain des FileMaker Servers, z. B. `fm.kunde.at` |
   | `FMS_CNAME_TARGET` | z. B. `_acme-challenge.fm-kunde.<zone>`, leer ohne CNAME |
   | `FMS_ADMIN_USER`, `FMS_ADMIN_PASSWORD` | Anmeldung an der Admin Console |
   | `ACME_DNS_URL`, `ACME_DNS_CLIENT`, `ACME_DNS_KEY` | URL des DNS-Dienstes, Clientname, Schlüssel |

   Dazu ein Service Account, der **nur dieses Environment** lesen darf (keine Tresore). Die Einrichtung fragt nach seinem Token und der Environment-ID (Manage environment → Copy environment ID).

## Was auf dem Server liegt

| Ort | Inhalt |
|---|---|
| `C:\Program Files\win-acme` | win-acme, `settings.json` mit Zeitplan 03:00 und Skript-Timeout 30 Min. |
| `C:\Program Files\1Password CLI` | `op.exe` (nur mit gültiger Signatur von AgileBits übernommen) |
| `C:\ProgramData\hgi\Zertifikat` | die Skripte, `zugang.json` (Environment-ID und Token, per DPAPI an diesen Server gebunden), `pem\`, `Logs\`. Zugriff nur SYSTEM und Administratoren. |

Außer dem Token liegt kein Geheimnis auf dem Server. Passwort und Schlüssel werden bei jedem Lauf frisch aus 1Password gelesen.

## Dateien

| Datei | Zweck |
|---|---|
| `Installieren.ps1` | Einstieg: lädt das Release, prüft die Prüfsumme, startet die Einrichtung |
| `Einrichten-FMS-Zertifikat.ps1` | die Einrichtung in den vier Modi |
| `DNS-Eintrag.ps1` | von win-acme aufgerufen: Prüfwert über den DNS-Dienst setzen und entfernen |
| `FMS-Zertifikat-Import.ps1` | von win-acme aufgerufen: prüfen, importieren, Datenbanken schließen, nur bei Erfolg neu starten, prüfen |
| `Zugang.ps1` | liest die Zugänge aus dem 1Password-Environment (`op run --environment`) |

## Releases

Im internen Repo einen Tag `fms-v<version>` setzen, z. B. `fms-v1.0.0`. Die CI legt hier das Release `v1.0.0` an.

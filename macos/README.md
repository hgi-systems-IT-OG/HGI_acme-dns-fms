# HGI_acme-dns-fms für macOS

SSL-Zertifikate von Let's Encrypt für FileMaker Server am Mac, automatisch erneuert über die DNS-01-Prüfung. Am Server muss dafür kein Port geöffnet werden. Vorbereitung, CNAME und 1Password-Environment sind dieselben wie unter Windows, siehe [README](../README.md).

> Dieser Ordner wird aus dem internen Repo `HGI_acme-dns` (Ordner `fms-macos/`) veröffentlicht. Änderungen bitte dort.

## Einrichtung

Im Terminal auf dem FileMaker Server, mit einem Administrator-Konto:

```bash
sudo bash -c "$(curl -fsSL https://github.com/hgi-systems-IT-OG/HGI_acme-dns-fms/releases/latest/download/installieren-macos.sh)"
```

Die Modi sind dieselben wie unter Windows:

| Modus | Was passiert |
|---|---|
| 1 Pruefen | Prüft 1Password, Anmeldung an der Admin Console, CNAME, CAA, Versionen. Legt nur `/Library/hgi/Zertifikat` mit dem Zugang an und installiert die 1Password CLI. An FileMaker Server ändert sich nichts. |
| 2 Staging | Richtet alles ein und holt ein **Test**-Zertifikat. Kein Import, kein Neustart, kein Zeitplan. Läuft mit leerer Umgebung, so wie später der LaunchDaemon. |
| 3 Produktiv | Holt das echte Zertifikat, **schließt die Datenbanken und startet FileMaker Server sofort neu**, legt den Zeitplan an. Nur im Wartungsfenster. |
| 4 Aktualisieren | Bringt Skripte, lego und 1Password CLI auf den neuesten Stand. Kein neues Zertifikat, kein Neustart. |

Danach startet ein LaunchDaemon täglich um 03:00 die Erneuerung. lego erneuert nur, wenn das Zertifikat fällig ist, und startet FileMaker Server dabei kurz neu.

## Unterschiede zu Windows

| | Windows | Mac |
|---|---|---|
| Zertifikat holen | win-acme | [lego](https://go-acme.github.io/lego/), spricht das Protokoll des DNS-Dienstes direkt (`httpreq`) |
| Zeitplan | geplante Aufgabe als SYSTEM | LaunchDaemon `com.hgisystems.fms-zertifikat` als root |
| Token | `zugang.json`, per DPAPI verschlüsselt | System-Schlüsselbund, nur für root |
| Neustart | Dienst `FileMaker Server` | `launchctl kickstart -k system/com.filemaker.fms` |

**Achtung CNAME-Kette:** lego folgt dem CNAME bis zum Ende und schreibt den Prüfwert dorthin. Zeigt das CNAME-Ziel selbst weiter, etwa über einen Platzhalter-Eintrag `*.hgisystems.com`, lehnt der DNS-Dienst den Namen ab. Der Modus Pruefen erkennt das und bricht mit einem Hinweis ab.

## Was auf dem Server liegt

| Ort | Inhalt |
|---|---|
| `/usr/local/bin/op` | 1Password CLI (nur mit gültiger Signatur von AgileBits installiert) |
| `/Library/hgi/Zertifikat` | `bin/lego`, die Skripte, `zugang.conf` (nur die Environment-ID), `lego/` (Konto und Zertifikat), `Logs/`. Zugriff nur root. |
| System-Schlüsselbund | Token des Service Accounts (`hgi-fms-zertifikat`) |
| `/Library/LaunchDaemons/com.hgisystems.fms-zertifikat.plist` | Zeitplan 03:00 |

## Dateien

| Datei | Zweck |
|---|---|
| `installieren.sh` | Einstieg: lädt das Release, prüft die Prüfsumme, startet die Einrichtung (im Release als `installieren-macos.sh`) |
| `einrichten.sh` | die Einrichtung in den vier Modi |
| `erneuern.sh` | vom LaunchDaemon aufgerufen: Zugänge aus 1Password lesen, lego starten |
| `import.sh` | von lego nach einer Erneuerung aufgerufen: prüfen, importieren, Datenbanken schließen, nur bei Erfolg neu starten, prüfen |
| `gemeinsam.sh` | Pfade, Schlüsselbund, 1Password, DNS-Dienst |

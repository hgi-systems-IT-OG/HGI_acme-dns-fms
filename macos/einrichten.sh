#!/bin/bash
#
#  einrichten.sh  (hgi systems)
#
#  Richtet auf einem FileMaker Server (macOS) die automatische Erneuerung des SSL-Zertifikats über
#  Let's Encrypt mit DNS-01-Prüfung ein. Als root ausführen. Normalerweise startet es
#  installieren.sh, siehe README. Gegenstück zu Einrichten-FMS-Zertifikat.ps1 unter Windows.
#
#  Voraussetzungen wie unter Windows:
#    - beim Kunden: CNAME  _acme-challenge.<Domain>  ->  _acme-challenge.fm-<KdNr>.acme.hgisystems.com
#    - beim DNS-Dienst: ein Client, der das CNAME-Ziel (ohne _acme-challenge.) beschreiben darf
#    - in 1Password: Environment des Kunden (siehe gemeinsam.sh) und ein Service Account, der NUR
#      dieses Environment lesen darf. Token und Environment-ID werden beim ersten Lauf abgefragt.
#
#  Aufruf:  einrichten.sh <Pruefen|Staging|Produktiv|Aktualisieren> [--zugaenge-neu] [--erneuerung-neu] [--ja]
#
#  Modi:
#    Pruefen       Prüft 1Password-Zugang, Anmeldung an der Admin Console, CNAME, CAA und die
#                  Versionen. Legt nur den hgi-Ordner mit dem Zugang an und installiert die
#                  1Password CLI; an FileMaker Server ändert es nichts.
#    Staging       Richtet alles ein und holt ein TEST-Zertifikat von Let's Encrypt (Staging).
#                  Kein Import, kein Neustart, kein Zeitplan. Danach Import-Skript als Dry-Run.
#                  Beides läuft über erneuern.sh mit leerer Umgebung, wie später der LaunchDaemon.
#    Produktiv     Holt das echte Zertifikat, importiert es SOFORT (Datenbanken werden geschlossen,
#                  FileMaker Server startet neu) und legt den täglichen Zeitplan an.
#    Aktualisieren Bringt nur Skripte, lego und 1Password CLI auf den neuesten Stand.
#
#  Was eingerichtet wird:
#    /usr/local/bin/op                  1Password CLI (nur mit gültiger Signatur von AgileBits)
#    /Library/hgi/Zertifikat            nur root hat Zugriff
#      bin/lego                         lego (Prüfsumme aus dem Release geprüft)
#      gemeinsam.sh, erneuern.sh, import.sh, einrichten.sh
#      zugang.conf                      ID des Environments (das Token liegt im System-Schlüsselbund)
#      lego/                            Konto bei Let's Encrypt und das aktuelle Zertifikat
#      Logs/
#    /Library/LaunchDaemons/com.hgisystems.fms-zertifikat.plist   täglich 03:00 erneuern.sh als root
#
#  --zugaenge-neu fragt Token und Environment-ID neu ab, z. B. nach einem neuen Service Account.

MODUS=$1; shift
ZUGAENGE_NEU=0; ERNEUERUNG_NEU=0; JA=0
for a in "$@"; do
    case "$a" in
        --zugaenge-neu)   ZUGAENGE_NEU=1 ;;
        --erneuerung-neu) ERNEUERUNG_NEU=1 ;;   # vorhandenes Zertifikat für diese Domain ersetzen
        --ja)             JA=1 ;;               # Sicherheitsabfrage im Modus Produktiv überspringen
        *) echo "Unbekannter Parameter: $a" >&2; exit 2 ;;
    esac
done
case "$MODUS" in Pruefen|Staging|Produktiv|Aktualisieren) ;; *)
    echo "Aufruf: $0 <Pruefen|Staging|Produktiv|Aktualisieren> [--zugaenge-neu] [--erneuerung-neu] [--ja]" >&2; exit 2 ;;
esac

QUELLE=$(cd "$(dirname "$0")" && pwd)
source "$QUELLE/gemeinsam.sh"

DAEMON_LABEL=com.hgisystems.fms-zertifikat
DAEMON_PLIST=/Library/LaunchDaemons/$DAEMON_LABEL.plist
UHRZEIT_STUNDE=3

schritt() { printf '\n\033[36m=== %s ===\033[0m\n' "$1"; }
ok()      { printf '  \033[32mOK\033[0m      %s\n' "$1"; }
hinweis() { printf '  \033[33mHINWEIS\033[0m %s\n' "$1"; }
abbruch() { printf '  \033[31mFEHLER\033[0m  %s\n\n\033[31mAbgebrochen.\033[0m\n' "$1"; exit 1; }
ende()    { printf '\n\033[32m%s\033[0m\n' "$1"; exit 0; }

[ "$(id -u)" = 0 ] || abbruch 'Bitte mit sudo als root ausführen'

TMP=$(mktemp -d /tmp/hgi-fms-zertifikat.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

# ======================================================================
schritt "Skripte nach $ORDNER ($MODUS)"
# ======================================================================
# Nur root darf lesen und schreiben. Wichtig, weil root die Skripte ausführt: Dürfte ein anderer
# Benutzer sie ändern, liefe sein Code mit vollen Rechten.
mkdir -p "$ORDNER/bin" "$LOGS"
for datei in gemeinsam.sh erneuern.sh import.sh einrichten.sh; do
    [ "$QUELLE" = "$ORDNER" ] || cp "$QUELLE/$datei" "$ORDNER/$datei"
done
chown -R root:wheel "$ORDNER"
chmod -R go-rwx "$ORDNER"
chmod 700 "$ORDNER"/*.sh
ok 'Skripte kopiert, Zugriff nur root'

mkdir -p "$LOGS"
exec > >(tee -a "$LOGS/einrichtung-$(date +%Y%m%d-%H%M%S).log") 2>&1

# ======================================================================
schritt '1Password CLI'
# ======================================================================
op_version=; op_neu=
[ -x "$OP" ] && op_version=$("$OP" --version 2>/dev/null)
op_neu=$(curl -fsS --max-time 30 'https://app-updates.agilebits.com/check/1/0/CLI2/en/2.0.0/N' |
    sed -n 's/.*"version":"\([0-9.]*\)".*/\1/p') || hinweis '1Password-Updateserver nicht erreichbar'
[ -n "$op_neu" ] || [ -n "$op_version" ] || abbruch '1Password CLI fehlt und der Updateserver ist nicht erreichbar'

if [ -n "$op_neu" ] && { [ -z "$op_version" ] || version_kleiner "$op_version" "$op_neu"; }; then
    paket="$TMP/op.pkg"
    curl -fsSL -o "$paket" "https://cache.agilebits.com/dist/1P/op2/pkg/v$op_neu/op_apple_universal_v$op_neu.pkg" ||
        abbruch '1Password CLI konnte nicht geladen werden'
    # op bekommt das Token, deshalb nur mit gültiger Signatur von AgileBits installieren
    signatur=$(pkgutil --check-signature "$paket" 2>&1)
    echo "$signatur" | grep -q 'Status: signed by a developer certificate issued by Apple' &&
        echo "$signatur" | grep -q 'Developer ID Installer: AgileBits Inc. (2BUA8C4S2C)' ||
        abbruch "Paket der 1Password CLI ist nicht gültig von AgileBits signiert: $(echo "$signatur" | head -3 | tr '\n' ' ')"
    installer -pkg "$paket" -target / >/dev/null || abbruch 'Installation der 1Password CLI fehlgeschlagen'
    ok "1Password CLI $op_neu installiert"
else
    ok "1Password CLI $op_version ist aktuell"
fi

# ======================================================================
schritt 'lego'
# ======================================================================
lego_version=; lego_neu=
[ -x "$LEGO" ] && lego_version=$("$LEGO" --version 2>/dev/null | grep -o '[0-9][0-9.]*' | head -1)
lego_neu=$(curl -fsS --max-time 30 https://api.github.com/repos/go-acme/lego/releases/latest |
    sed -n 's/.*"tag_name": *"v\([0-9.]*\)".*/\1/p') || hinweis 'GitHub nicht erreichbar, lego kann nicht geprüft werden'
lego_veraltet=0
[ -n "$lego_neu" ] && { [ -z "$lego_version" ] || version_kleiner "$lego_version" "$lego_neu"; } && lego_veraltet=1

if [ "$MODUS" = Pruefen ]; then
    # Nur berichten, nichts installieren
    if [ -n "$lego_version" ]; then ok "lego $lego_version in $LEGO"; else hinweis "lego nicht in $LEGO"; fi
    [ $lego_veraltet = 1 ] && hinweis "neuere lego-Version: $lego_neu"
else
    [ -n "$lego_neu" ] || [ -n "$lego_version" ] || abbruch 'lego fehlt und GitHub ist nicht erreichbar'
    if [ $lego_veraltet = 1 ]; then
        case "$(uname -m)" in arm64) arch=arm64 ;; x86_64) arch=amd64 ;; *) abbruch "Unbekannte Architektur $(uname -m)" ;; esac
        datei="lego_v${lego_neu}_darwin_${arch}.tar.gz"
        basis="https://github.com/go-acme/lego/releases/download/v$lego_neu"
        curl -fsSL -o "$TMP/$datei" "$basis/$datei" &&
            curl -fsSL -o "$TMP/checksums.txt" "$basis/lego_${lego_neu}_checksums.txt" || abbruch 'lego konnte nicht geladen werden'
        soll=$(awk -v d="$datei" '$2 == d { print $1 }' "$TMP/checksums.txt")
        ist=$(shasum -a 256 "$TMP/$datei" | awk '{ print $1 }')
        [ -n "$soll" ] && [ "$soll" = "$ist" ] || abbruch "Prüfsumme von $datei stimmt nicht ($ist statt $soll)"
        tar -xzf "$TMP/$datei" -C "$TMP" lego || abbruch 'lego-Paket nicht entpackbar'
        install -o root -g wheel -m 700 "$TMP/lego" "$LEGO"
        ok "lego $lego_neu installiert"
    else
        ok "lego $lego_version ist aktuell"
    fi
fi

[ "$MODUS" = Aktualisieren ] && ende 'Aktualisiert. Zertifikat und Zeitplan unverändert.'

# ======================================================================
schritt 'Zugang zu 1Password'
# ======================================================================
if [ $ZUGAENGE_NEU = 1 ] || [ -z "$(environment_id)" ] || [ -z "$(token_lesen)" ]; then
    printf 'Token des 1Password Service Accounts für diesen Kunden: '
    read -rs token < /dev/tty; echo
    [ -n "$token" ] || abbruch 'Kein Token eingegeben'
    printf 'ID des 1Password Environments (Developer > Environments > Manage environment): '
    read -r environment < /dev/tty
    [[ "$environment" =~ ^[a-z0-9]{26}$ ]] || abbruch "Keine gültige Environment-ID: '$environment'"
    environment_lesen "$token" "$environment" 2>"$TMP/op-fehler" || abbruch "1Password: $(cat "$TMP/op-fehler")"
    # Der Service Account eines Kunden soll nur das Environment sehen, keine Tresore.
    tresore=$(op_mit_token "$token" vault list --format json 2>/dev/null | grep -c '"id"')
    [ "${tresore:-0}" -eq 0 ] || abbruch "Der Service Account sieht $tresore Tresore, erwartet: nur das Environment"
    fehlt=
    for v in FMS_DOMAIN FMS_ADMIN_USER FMS_ADMIN_PASSWORD ACME_DNS_URL ACME_DNS_CLIENT ACME_DNS_KEY; do
        [ -n "${!v}" ] || fehlt="$fehlt $v"
    done
    [ -z "$fehlt" ] || abbruch "Im Environment fehlt:$fehlt"
    token_speichern "$token" || abbruch 'Token konnte nicht im System-Schlüsselbund gespeichert werden'
    token=
    echo "ENVIRONMENT=$environment" > "$ZUGANG_DATEI"
    chmod 600 "$ZUGANG_DATEI"
    ok "Environment $environment, Token im System-Schlüsselbund gespeichert"
else
    environment_laden 2>"$TMP/op-fehler" || abbruch "1Password: $(cat "$TMP/op-fehler")"
    ok "Environment $(environment_id) (gespeichert)"
fi

DOMAIN=$FMS_DOMAIN
CNAME_ZIEL=$FMS_CNAME_TARGET
[ -n "$DOMAIN" ] || abbruch 'FMS_DOMAIN im Environment ist leer'
ok "Domain $DOMAIN$([ -n "$CNAME_ZIEL" ] && echo ", CNAME-Ziel $CNAME_ZIEL" || echo ', ohne CNAME')"

# --- Admin Console ---
FMS=$(fmsadmin_pfad) || abbruch 'FileMaker Server nicht gefunden (fmsadmin)'
"$FMS" list files -u "$FMS_ADMIN_USER" -p "$FMS_ADMIN_PASSWORD" >/dev/null 2>&1 ||
    abbruch 'Anmeldung an der Admin Console mit den Daten aus 1Password fehlgeschlagen'
ok "Admin Console: Anmeldung als $FMS_ADMIN_USER"
launchctl print "$FMS_DIENST" >/dev/null 2>&1 || abbruch "LaunchDaemon $FMS_DIENST nicht gefunden, Neustart nach dem Import wäre nicht möglich"
ok "FileMaker Server läuft als $FMS_DIENST"

# --- DNS-Dienst (geprüft wird er im Schritt DNS-Kette) ---
[ -n "$ACME_DNS_URL" ] && [ -n "$ACME_DNS_CLIENT" ] && [ -n "$ACME_DNS_KEY" ] ||
    abbruch 'DNS-Dienst: ACME_DNS_URL, ACME_DNS_CLIENT oder ACME_DNS_KEY im Environment leer'
ok "DNS-Dienst: Client $ACME_DNS_CLIENT, $ACME_DNS_URL"

# ======================================================================
schritt "DNS beim Kunden - $DOMAIN"
# ======================================================================
# Hierhin schreibt der DNS-Dienst den Prüfwert: das CNAME-Ziel, sonst direkt unter der Domain.
TXT_NAME=${CNAME_ZIEL:-_acme-challenge.$DOMAIN}
case "$TXT_NAME" in _acme-challenge.*) ;; *) abbruch "CNAME-Ziel muss mit _acme-challenge. beginnen ($CNAME_ZIEL)" ;; esac

cname_von() { dig +short CNAME "$1" @"$DNS_SERVER" | sed 's/\.$//' | head -1; }

cname=$(cname_von "_acme-challenge.$DOMAIN")
if [ -n "$CNAME_ZIEL" ]; then
    [ -n "$cname" ] || abbruch "Kein CNAME für _acme-challenge.$DOMAIN - beim DNS-Anbieter des Kunden eintragen: -> $CNAME_ZIEL"
    [ "$cname" = "$CNAME_ZIEL" ] || abbruch "CNAME zeigt auf $cname statt auf $CNAME_ZIEL"
    ok "CNAME _acme-challenge.$DOMAIN -> $CNAME_ZIEL"
else
    [ -z "$cname" ] || abbruch "Es gibt einen CNAME _acme-challenge.$DOMAIN -> $cname, dann im Environment als FMS_CNAME_TARGET eintragen"
fi

# lego folgt CNAMEs bis zum Ende der Kette und schreibt dorthin. Zeigt das Ziel selbst weiter
# (z. B. über einen Platzhalter-Eintrag *.hgisystems.com), lehnt der DNS-Dienst den Namen ab.
weiter=$(cname_von "$TXT_NAME")
[ -z "$weiter" ] || abbruch "$TXT_NAME zeigt per CNAME weiter auf $weiter (Platzhalter-Eintrag in der hgi-Zone?). lego würde dorthin schreiben. In Cloudflare z. B. einen TXT-Eintrag *.acme.hgisystems.com anlegen, damit der Platzhalter dort nicht greift."
ok "$TXT_NAME ist das Ende der CNAME-Kette"

# CAA: Der erste Name von unten, der CAA-Einträge hat, entscheidet.
name=$DOMAIN; caa_geprueft=0
while [ "$name" != "${name#*.}" ]; do
    caa=$(dig +short CAA "$name" @"$DNS_SERVER")
    if [ -n "$caa" ]; then
        echo "$caa" | grep -q 'issue "letsencrypt.org' ||
            abbruch "CAA auf $name erlaubt Let's Encrypt nicht: $(echo "$caa" | tr '\n' ' ') - 'letsencrypt.org' ergänzen lassen"
        ok "CAA auf $name erlaubt Let's Encrypt"
        caa_geprueft=1
        break
    fi
    name=${name#*.}
done
[ $caa_geprueft = 1 ] || ok 'Kein CAA-Eintrag, alle Aussteller erlaubt'

[ "$MODUS" = Pruefen ] && ende 'Prüfung abgeschlossen. An FileMaker Server wurde nichts geändert.'

# ======================================================================
schritt "DNS-Kette testen (ohne Let's Encrypt)"
# ======================================================================
# Ein Zufallswert geht über den DNS-Dienst nach Cloudflare und muss dann unter
# _acme-challenge.<Domain> sichtbar werden, gegebenenfalls über den CNAME des Kunden.
testwert=$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=\n')   # 43 Zeichen wie bei ACME
dns_eintrag present "$TXT_NAME" "$testwert" 2>"$TMP/dns-fehler" || abbruch "DNS-Dienst hat den Eintrag abgelehnt: $(cat "$TMP/dns-fehler")"
gefunden=0; bis=$(( $(date +%s) + 120 ))
while [ $gefunden = 0 ] && [ "$(date +%s)" -lt $bis ]; do
    sleep 10
    dig +short TXT "_acme-challenge.$DOMAIN" @"$DNS_SERVER" | tr -d '"' | grep -qxF "$testwert" && gefunden=1
done
dns_eintrag cleanup "$TXT_NAME" "$testwert" 2>/dev/null
[ $gefunden = 1 ] || abbruch "Testwert nach 2 Min. nicht unter _acme-challenge.$DOMAIN sichtbar"
ok "Testwert kommt über den DNS-Dienst an ($TXT_NAME), wieder entfernt"

# erneuern.sh mit leerer Umgebung starten, wie es der LaunchDaemon tut: Alles, was es braucht,
# muss es sich selbst holen (Token aus dem Schlüsselbund, Zugänge aus 1Password).
erneuern_wie_launchd() {
    env -i HOME=/var/root ${ERNEUERUNG_ERZWINGEN:+ERNEUERUNG_ERZWINGEN=1} /bin/bash "$ORDNER/erneuern.sh" "$@"
}

# ======================================================================
if [ "$MODUS" = Staging ]; then
    schritt "Test-Zertifikat von Let's Encrypt (Staging) und Import als Dry-Run"
# ======================================================================
    rm -rf "$ORDNER/lego-staging"
    erneuern_wie_launchd --staging
    rc=$?
    rm -rf "$ORDNER/lego-staging"   # Test-Zertifikat und Staging-Konto werden nicht mehr gebraucht
    [ $rc = 0 ] || abbruch "Staging fehlgeschlagen (Exit-Code $rc), siehe Ausgabe oben und $LOGS/fms-zertifikat.log"
    ok 'Test-Zertifikat erhalten, Import-Skript: Dateien, Schlüssel, Domain, Admin-Zugang und Neustart-Dienst in Ordnung'
    ende 'Staging erfolgreich. Nächster Schritt: Produktiv in einem Wartungsfenster.'
fi

# ======================================================================
schritt "Zertifikat von Let's Encrypt (produktiv)"
# ======================================================================
if [ -f "$ORDNER/lego/certificates/$DOMAIN.crt" ]; then
    [ $ERNEUERUNG_NEU = 1 ] || abbruch "Für $DOMAIN gibt es schon ein Zertifikat. Ersetzen mit: sudo /bin/bash $ORDNER/einrichten.sh Produktiv --erneuerung-neu"
    export ERNEUERUNG_ERZWINGEN=1
fi
if [ $JA = 0 ]; then
    echo
    echo '  Der produktive Lauf importiert das Zertifikat SOFORT: Die Datenbanken werden geschlossen'
    echo '  (Clients 60 s vorher gewarnt) und FileMaker Server startet neu.'
    printf '  Fortfahren? JA eingeben: '
    read -r antwort < /dev/tty
    [ "$antwort" = JA ] || abbruch 'Nicht bestätigt'
fi
erneuern_wie_launchd || abbruch "lego oder Import meldet einen Fehler. Import-Log: $LOGS/fms-zertifikat.log"
[ -f "$ORDNER/lego/certificates/$DOMAIN.crt" ] || abbruch "Kein Zertifikat in $ORDNER/lego/certificates"
ok 'Zertifikat ausgestellt und importiert'

# ======================================================================
schritt 'Zeitplan (LaunchDaemon)'
# ======================================================================
cat > "$DAEMON_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$DAEMON_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$ORDNER/erneuern.sh</string>
    </array>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key>
        <integer>$UHRZEIT_STUNDE</integer>
        <key>Minute</key>
        <integer>0</integer>
    </dict>
    <key>StandardOutPath</key>
    <string>$LOGS/erneuern.log</string>
    <key>StandardErrorPath</key>
    <string>$LOGS/erneuern.log</string>
</dict>
</plist>
EOF
chown root:wheel "$DAEMON_PLIST"
chmod 644 "$DAEMON_PLIST"
launchctl bootout "system/$DAEMON_LABEL" >/dev/null 2>&1
launchctl bootstrap system "$DAEMON_PLIST" || abbruch "LaunchDaemon $DAEMON_LABEL konnte nicht geladen werden"
launchctl print "system/$DAEMON_LABEL" >/dev/null 2>&1 || abbruch "LaunchDaemon $DAEMON_LABEL ist nicht geladen"
ok "$DAEMON_LABEL täglich $UHRZEIT_STUNDE:00 als root (lego wartet vor einer Erneuerung zufällig bis zu 8 Min.)"

ende 'Einrichtung abgeschlossen. Kunde in die Kundenliste eintragen.'

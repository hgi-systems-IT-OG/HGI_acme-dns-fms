#!/bin/bash
#
#  gemeinsam.sh  (hgi systems)
#
#  Pfade und Funktionen, die alle Skripte für den Mac brauchen. Wird per "source" eingebunden.
#  Gegenstück zu Zugang.ps1 unter Windows.
#
#  Alles Kundenspezifische liegt in 1Password, ein Environment pro Kunde (z. B. "6819 (Willi GmbH)"):
#      FMS_DOMAIN           Domain des FileMaker Servers, z. B. fms.kunde.at
#      FMS_CNAME_TARGET     Ziel des CNAME _acme-challenge.<FMS_DOMAIN> (leer, wenn die Domain selbst
#                           in der Cloudflare-Zone von hgi liegt)
#      FMS_ADMIN_USER       Benutzer / Passwort der Admin Console von FileMaker Server
#      FMS_ADMIN_PASSWORD
#      ACME_DNS_URL         URL des hgi-DNS-Dienstes
#      ACME_DNS_CLIENT      Clientname / Schlüssel beim DNS-Dienst
#      ACME_DNS_KEY
#  Gelesen wird mit der 1Password CLI (op run --environment) über einen Service Account, der NUR
#  dieses Environment sieht.
#
#  Auf dem Server liegen nur die ID des Environments (zugang.conf, kein Geheimnis) und das Token des
#  Service Accounts im System-Schlüsselbund. Lesen kann das Token nur root.
#
#  Alle Skripte laufen mit /bin/bash 3.2 (Standard am Mac): keine assoziativen Arrays, kein mapfile.

ORDNER=/Library/hgi/Zertifikat          # ohne Leerzeichen: lego zerlegt den Hook-Befehl an Leerzeichen
LOGS="$ORDNER/Logs"
LEGO="$ORDNER/bin/lego"
OP=/usr/local/bin/op                    # dorthin installiert das Paket von AgileBits
ZUGANG_DATEI="$ORDNER/zugang.conf"
SCHLUESSELBUND=/Library/Keychains/System.keychain
SCHLUESSELBUND_DIENST=hgi-fms-zertifikat
SCHLUESSELBUND_KONTO=service-account
FMS_DIENST=system/com.filemaker.fms     # LaunchDaemon von FileMaker Server
DNS_SERVER=1.1.1.1                      # Cloudflare, unabhängig vom DNS-Server des Kunden

export PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin

# Pfad zu fmsadmin, leer wenn FileMaker Server fehlt
fmsadmin_pfad() {
    local p
    for p in /usr/local/bin/fmsadmin "/Library/FileMaker Server/Database Server/bin/fmsadmin"; do
        if [ -x "$p" ]; then echo "$p"; return 0; fi
    done
    return 1
}

# Versionsvergleich: version_kleiner 2.40.0 2.41.1 ist wahr
version_kleiner() {
    [ "$1" = "$2" ] && return 1
    local a b i
    IFS=. read -r -a a <<< "$1"
    IFS=. read -r -a b <<< "$2"
    for i in 0 1 2 3; do
        if [ "${a[$i]:-0}" -lt "${b[$i]:-0}" ]; then return 0; fi
        if [ "${a[$i]:-0}" -gt "${b[$i]:-0}" ]; then return 1; fi
    done
    return 1
}

# --- Token im System-Schlüsselbund ---

# Das Token geht über stdin an "security", damit es nicht in der Prozessliste steht.
token_speichern() {
    printf 'add-generic-password -U -a "%s" -s "%s" -T /usr/bin/security -w "%s" "%s"\n' \
        "$SCHLUESSELBUND_KONTO" "$SCHLUESSELBUND_DIENST" "$1" "$SCHLUESSELBUND" | security -i >/dev/null
}

token_lesen() {
    security find-generic-password -a "$SCHLUESSELBUND_KONTO" -s "$SCHLUESSELBUND_DIENST" -w "$SCHLUESSELBUND" 2>/dev/null
}

environment_id() {
    [ -f "$ZUGANG_DATEI" ] && sed -n 's/^ENVIRONMENT=//p' "$ZUGANG_DATEI"
}

# --- 1Password ---

# op mit dem Token aufrufen. Das Token steht nur für diesen einen Aufruf in der Umgebung.
op_mit_token() {
    local token=$1; shift
    OP_SERVICE_ACCOUNT_TOKEN="$token" "$OP" "$@"
}

# Liest alle FMS_*- und ACME_*-Variablen eines Environments und exportiert sie in die laufende Shell.
# op run startet dafür /usr/bin/env; --no-masking, weil die Werte hier gebraucht werden.
# Sie landen nur in Variablen, nicht in Ausgabe oder Log.
# Aufruf: environment_lesen <token> <environment-id>   (Fehlertext von op auf stderr, Rückgabe 1)
environment_lesen() {
    local ausgabe zeile
    ausgabe=$(op_mit_token "$1" run --environment "$2" --no-masking -- /usr/bin/env) || return 1
    while IFS= read -r zeile; do
        case "$zeile" in
            FMS_*=*|ACME_*=*) export "$zeile" ;;
        esac
    done < <(printf '%s\n' "$ausgabe")
}

# Wie environment_lesen, aber mit Token aus dem Schlüsselbund und der gespeicherten Environment-ID.
environment_laden() {
    local token id
    id=$(environment_id)
    token=$(token_lesen)
    if [ -z "$id" ] || [ -z "$token" ]; then
        echo "Zugang fehlt: $ZUGANG_DATEI oder Token im System-Schlüsselbund" >&2
        return 1
    fi
    environment_lesen "$token" "$id"
}

# --- DNS-Dienst (lego-"httpreq"-Protokoll) ---

# dns_eintrag present|cleanup <fqdn ohne Punkt am Ende> <wert>
# Clientname und Schlüssel gehen per -K über stdin an curl, nicht über die Kommandozeile.
dns_eintrag() {
    printf 'user = "%s:%s"\n' "$ACME_DNS_CLIENT" "$ACME_DNS_KEY" |
        curl -fsS -K - -X POST "${ACME_DNS_URL%/}/$1" \
            -H 'Content-Type: application/json' \
            -d "{\"fqdn\":\"$2.\",\"value\":\"$3\"}" >/dev/null
}

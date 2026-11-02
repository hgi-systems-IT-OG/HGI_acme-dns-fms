#!/bin/bash
#
#  erneuern.sh  (hgi systems)
#
#  Läuft täglich um 03:00 als LaunchDaemon (root). Liest die Zugänge aus 1Password und ruft lego auf.
#  lego erneuert nur, wenn das Zertifikat fällig ist, und startet dann import.sh (deploy-hook).
#  Ausgabe: Logs/erneuern.log (über den LaunchDaemon), Import: Logs/fms-zertifikat.log
#
#  --staging  holt ein TEST-Zertifikat von Let's Encrypt (Staging) in lego-staging/ und ruft
#             import.sh nur als Dry-Run auf. Das Einrichtungsskript nutzt das im Modus Staging,
#             damit derselbe Weg geprüft wird, den später der LaunchDaemon nimmt.
#
#  Exit-Code: 0 OK oder nichts fällig, sonst Fehler (lego bzw. import.sh)

source "$(dirname "$0")/gemeinsam.sh"

STAGING=0
[ "$1" = --staging ] && STAGING=1

echo "$(date '+%Y-%m-%d %H:%M:%S')  ===== erneuern.sh$([ $STAGING = 1 ] && echo ' --staging') ====="

environment_laden || { echo 'Zugänge aus 1Password nicht lesbar'; exit 1; }
[ -n "$FMS_DOMAIN" ] || { echo 'FMS_DOMAIN im Environment ist leer'; exit 1; }

# lego schreibt den Prüfwert über den DNS-Dienst (Provider httpreq) und folgt dabei selbst dem
# CNAME _acme-challenge.<Domain> -> FMS_CNAME_TARGET.
export HTTPREQ_ENDPOINT="$ACME_DNS_URL"
export HTTPREQ_USERNAME="$ACME_DNS_CLIENT"
export HTTPREQ_PASSWORD="$ACME_DNS_KEY"

# RSA wie unter Windows; --no-bundle, damit .crt nur das Server-Zertifikat enthält und die
# Zwischenzertifikate getrennt in .issuer.crt liegen (so will es fmsadmin certificate import).
lego_basis=(run --accept-tos --key-type RSA2048 --no-bundle --dns httpreq -d "$FMS_DOMAIN")

if [ $STAGING = 1 ]; then
    pfad="$ORDNER/lego-staging"
    "$LEGO" "${lego_basis[@]}" --server letsencrypt-staging --path "$pfad" || exit 1
    "$ORDNER/import.sh" --dry-run --domain "$FMS_DOMAIN" \
        --cert  "$pfad/certificates/$FMS_DOMAIN.crt" \
        --key   "$pfad/certificates/$FMS_DOMAIN.key" \
        --chain "$pfad/certificates/$FMS_DOMAIN.issuer.crt"
    exit $?
fi

# Import mit Schließen und Neustart dauert länger als die 2 Minuten, die lego Hooks standardmäßig lässt.
# --renew-force nur, wenn das Einrichtungsskript ein vorhandenes Zertifikat ersetzen soll.
"$LEGO" "${lego_basis[@]}" --path "$ORDNER/lego" \
    --deploy-hook "$ORDNER/import.sh" --deploy-hook-timeout 30m \
    ${ERNEUERUNG_ERZWINGEN:+--renew-force}

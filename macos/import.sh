#!/bin/bash
#
#  import.sh  (hgi systems)
#
#  Spielt ein neues Zertifikat in FileMaker Server ein. lego ruft es nach einer erfolgreichen
#  Erneuerung als deploy-hook auf und übergibt die Dateien in LEGO_HOOK_*-Variablen.
#  Gegenstück zu FMS-Zertifikat-Import.ps1 unter Windows, gleicher Ablauf und gleiche Exit-Codes:
#    1. Prüfen     Dateien vorhanden, Schlüssel passt zum Zertifikat, Domain im Zertifikat, nicht abgelaufen
#    2. Import     fmsadmin certificate import
#    3. Schließen  fmsadmin close mit Vorwarnung an die Clients
#    4. Warten     bis ALLE Datenbanken zu sind (fmsadmin list files), mit Timeout
#    5. Neustart   LaunchDaemon com.filemaker.fms - nur wenn 2. bis 4. erfolgreich waren
#    6. Prüfen     fmsadmin antwortet, Datenbanken offen, Server liefert das neue Zertifikat aus
#
#  Schlägt etwas vor dem Neustart fehl, wird NICHT neu gestartet. Wurden die Datenbanken schon
#  geschlossen, werden sie wieder geöffnet.
#
#  Aufruf von Hand:
#    import.sh [--dry-run] --cert <datei> --key <datei> --chain <datei> [--domain <domain>]
#  --dry-run prüft nur (Dateien, Schlüssel, fmsadmin, offene Datenbanken, LaunchDaemon) und ändert nichts.
#
#  Exit-Codes:
#     0  OK
#    10  Datei fehlt                     11  Schlüssel passt nicht zum Zertifikat
#    12  Domain nicht im Zertifikat      13  Zertifikat abgelaufen / läuft binnen 24 h ab
#    14  fmsadmin-Zugang fehlgeschlagen
#    20  Import fehlgeschlagen           (kein Neustart)
#    30  Schließen nicht bestätigt       (kein Neustart, Datenbanken wieder geöffnet)
#    40  Neustart fehlgeschlagen
#    50  Server nach Neustart nicht erreichbar oder Datenbanken nicht offen
#    51  Server liefert nicht das neue Zertifikat aus
#
#  Hinweis: fmsadmin bekommt das Passwort per -p übergeben und ist damit während des Laufs in der
#  Prozessliste sichtbar (wie unter Windows).

source "$(dirname "$0")/gemeinsam.sh"

CLOSE_WARN_SEC=${CLOSE_WARN_SEC:-60}      # Vorwarnzeit für verbundene Clients
CLOSE_TIMEOUT_MIN=${CLOSE_TIMEOUT_MIN:-5}    # so lange zusätzlich warten, bis alle Datenbanken zu sind
START_TIMEOUT_MIN=${START_TIMEOUT_MIN:-5}    # so lange nach dem Neustart auf fmsadmin warten
LOG_DATEI="$LOGS/fms-zertifikat.log"

DRY_RUN=0
CERT=$LEGO_HOOK_CERT_PATH
KEY=$LEGO_HOOK_CERT_KEY_PATH
CHAIN=$LEGO_HOOK_ISSUER_CERT_PATH
DOMAIN=
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --cert)    CERT=$2;   shift ;;
        --key)     KEY=$2;    shift ;;
        --chain)   CHAIN=$2;  shift ;;
        --domain)  DOMAIN=$2; shift ;;
        *) echo "Unbekannter Parameter: $1" >&2; exit 2 ;;
    esac
    shift
done

log() {
    local zeile
    zeile="$(date '+%Y-%m-%d %H:%M:%S')  $1"
    echo "$zeile"
    mkdir -p "$LOGS"
    echo "$zeile" >> "$LOG_DATEI"
}

fail() {
    log "FEHLER ($2): $1"
    exit "$2"
}

# --- Admin-Console-Zugang ---
# Unter lego erbt das Skript die Variablen von erneuern.sh, von Hand werden sie frisch gelesen.
if [ -z "$FMS_ADMIN_USER" ]; then
    environment_laden 2>>"$LOG_DATEI" || fail 'Zugangsdaten nicht lesbar (1Password)' 14
fi
[ -n "$DOMAIN" ] || DOMAIN=$FMS_DOMAIN
FMS=$(fmsadmin_pfad) || fail 'fmsadmin nicht gefunden' 14

fms()            { "$FMS" "$@" -u "$FMS_ADMIN_USER" -p "$FMS_ADMIN_PASSWORD"; }
offene_dateien() { fms list files 2>/dev/null | grep -c '\.fmp12'; }   # gibt die Anzahl aus

log "===== Start$([ $DRY_RUN = 1 ] && echo ' (DRY-RUN)') - $DOMAIN ====="

# ===== 1. Prüfen =====
for f in "$CERT" "$KEY" "$CHAIN"; do
    [ -n "$f" ] && [ -f "$f" ] || fail "Datei fehlt: $f" 10
done

pub_cert=$(openssl x509 -in "$CERT" -noout -pubkey 2>/dev/null)
pub_key=$(openssl pkey -in "$KEY" -pubout 2>/dev/null)
[ -n "$pub_cert" ] && [ "$pub_cert" = "$pub_key" ] || fail 'Schlüssel passt nicht zum Zertifikat' 11

openssl x509 -in "$CERT" -noout -text 2>/dev/null | grep -o 'DNS:[^,[:space:]]*' | grep -qxF "DNS:$DOMAIN" ||
    fail "Domain $DOMAIN nicht im Zertifikat" 12

openssl x509 -in "$CERT" -noout -checkend 86400 >/dev/null || fail 'Zertifikat ist abgelaufen oder läuft binnen 24 h ab' 13
log "Zertifikat OK: $(openssl x509 -in "$CERT" -noout -subject -enddate | tr '\n' ' ')"

# fms list files liefert bei falschem Passwort einen Fehler, bei 0 offenen Dateien eine leere Liste.
fms list files >/dev/null 2>&1 || fail 'fmsadmin-Zugang fehlgeschlagen (Benutzer/Passwort?)' 14
log "Offene Datenbanken: $(offene_dateien)"

if [ $DRY_RUN = 1 ]; then
    launchctl print "$FMS_DIENST" >/dev/null 2>&1 || fail "LaunchDaemon $FMS_DIENST nicht gefunden, Neustart wäre nicht möglich" 40
    log "DRY-RUN: würde importieren, $(offene_dateien) Datenbank(en) schließen (Vorwarnung $CLOSE_WARN_SEC s), auf das Schließen warten und $FMS_DIENST neu starten."
    log '===== Ende (DRY-RUN, nichts geändert) ====='
    exit 0
fi

# ===== 2. Import =====
ausgabe=$(fms certificate import "$CERT" --keyfile "$KEY" --intermediateCA "$CHAIN" -y 2>&1)
rc=$?
log "fmsadmin certificate import: $(echo "$ausgabe" | tr '\n' ' ')"
[ $rc -eq 0 ] || fail "Import fehlgeschlagen (ExitCode $rc) - KEIN Neustart" 20

# ===== 3. Datenbanken schließen =====
log "Schließe Datenbanken, Vorwarnung $CLOSE_WARN_SEC s"
fms close -y -t "$CLOSE_WARN_SEC" -m "Wartung: Der Server startet in $CLOSE_WARN_SEC Sekunden kurz neu." >/dev/null 2>&1

# ===== 4. Warten, bis ALLE zu sind =====
# Eine leere Liste zählt nur, wenn fmsadmin sie ohne Fehler geliefert hat. Schlägt die Abfrage
# fehl, ist nichts bestätigt und es wird weiter gewartet.
ende=$(( $(date +%s) + CLOSE_WARN_SEC + CLOSE_TIMEOUT_MIN * 60 ))
while :; do
    sleep 10
    if liste=$(fms list files 2>/dev/null); then
        offen=$(echo "$liste" | grep -c '\.fmp12')
        log "Noch offen: $offen"
        [ "$offen" -eq 0 ] && break
    else
        offen=unbekannt
        log 'Abfrage der offenen Datenbanken fehlgeschlagen - zählt als noch offen'
    fi
    [ "$(date +%s)" -lt "$ende" ] || break
done

if [ "$offen" != 0 ]; then
    log 'Timeout - öffne alle Datenbanken wieder'
    fms open -y >/dev/null 2>&1
    fail "Schließen nicht bestätigt (noch offen: $offen) - KEIN Neustart. Zertifikat ist importiert, aber erst nach einem Neustart aktiv." 30
fi

# ===== 5. FileMaker Server neu starten =====
# kickstart -k beendet den Dienst und startet ihn wieder (wie Restart-Service unter Windows).
log "Alle Datenbanken geschlossen - starte $FMS_DIENST neu"
launchctl kickstart -k "$FMS_DIENST" >/dev/null 2>&1 || fail "Neustart fehlgeschlagen (launchctl kickstart $FMS_DIENST)" 40

# ===== 6. Prüfen =====
ende=$(( $(date +%s) + START_TIMEOUT_MIN * 60 ))
until fms list files >/dev/null 2>&1; do
    [ "$(date +%s)" -lt "$ende" ] || fail "fmsadmin antwortet $START_TIMEOUT_MIN Min. nach dem Neustart nicht" 50
    sleep 10
done

if [ "$(offene_dateien)" -eq 0 ]; then
    log 'Keine Datenbank offen - öffne alle'
    fms open -y >/dev/null 2>&1
    sleep 15
fi
offen=$(offene_dateien)
[ "$offen" -gt 0 ] || fail 'Nach dem Neustart ist keine Datenbank offen' 50
log "Offene Datenbanken: $offen"

served=$(openssl s_client -connect 127.0.0.1:443 -servername "$DOMAIN" </dev/null 2>/dev/null | openssl x509 -noout -pubkey 2>/dev/null)
[ "$served" = "$pub_cert" ] || fail 'Server liefert auf 443 nicht das neue Zertifikat aus' 51
log 'Server liefert das neue Zertifikat aus'

log '===== Ende OK ====='
exit 0

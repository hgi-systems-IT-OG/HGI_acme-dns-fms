#!/bin/bash
#
#  installieren.sh  (hgi systems)
#
#  Einstieg mit einem Befehl, im Terminal auf dem FileMaker Server (macOS):
#
#    sudo bash -c "$(curl -fsSL https://github.com/hgi-systems-IT-OG/HGI_acme-dns-fms/releases/latest/download/installieren-macos.sh)"
#
#  Fragt nach dem Modus, lädt das neueste Paket aus demselben Release, prüft die Prüfsumme und
#  startet einrichten.sh. Beim ersten Lauf fragt das noch nach dem Token des 1Password Service
#  Accounts und der ID des Environments, alles andere kommt aus 1Password.
#
#  Eine bestimmte Version statt der neuesten: in der URL "latest/download" durch
#  "download/<tag>" ersetzen.

REPO=hgi-systems-IT-OG/HGI_acme-dns-fms
BASIS="https://github.com/$REPO/releases/latest/download"
PAKET=HGI_acme-dns-fms-macos.tar.gz

if [ "$(id -u)" != 0 ]; then
    echo 'Bitte mit sudo starten (siehe Befehl oben).' >&2
    exit 1
fi

printf "\n\033[36mFileMaker Server: Zertifikat über Let's Encrypt (hgi systems)\033[0m\n\n"
echo '  1  Pruefen        nichts an FileMaker Server ändern, nur prüfen'
echo '  2  Staging        alles einrichten, Test-Zertifikat, kein Neustart'
echo '  3  Produktiv      echtes Zertifikat, FileMaker Server startet SOFORT neu'
echo '  4  Aktualisieren  nur Skripte, lego und 1Password CLI erneuern'
printf '\nModus (1-4): '
read -r wahl < /dev/tty
case "$wahl" in
    1) modus=Pruefen ;;
    2) modus=Staging ;;
    3) modus=Produktiv ;;
    4) modus=Aktualisieren ;;
    *) echo 'Abgebrochen.' >&2; exit 1 ;;
esac

tmp=$(mktemp -d /tmp/hgi-fms-zertifikat-paket.XXXXXX)
trap 'rm -rf "$tmp"' EXIT

echo
echo "Lade $BASIS/$PAKET ..."
curl -fsSL -o "$tmp/$PAKET" "$BASIS/$PAKET" &&
    curl -fsSL -o "$tmp/$PAKET.sha256" "$BASIS/$PAKET.sha256" || { echo 'Download fehlgeschlagen.' >&2; exit 1; }

soll=$(awk '{ print $1 }' "$tmp/$PAKET.sha256")
ist=$(shasum -a 256 "$tmp/$PAKET" | awk '{ print $1 }')
if [ "$ist" != "$soll" ]; then
    echo "Prüfsumme stimmt nicht ($ist statt $soll). Abgebrochen." >&2
    exit 1
fi

mkdir "$tmp/entpackt"
tar -xzf "$tmp/$PAKET" -C "$tmp/entpackt" || { echo 'Paket nicht entpackbar.' >&2; exit 1; }
/bin/bash "$tmp/entpackt/einrichten.sh" "$modus"

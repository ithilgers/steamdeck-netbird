#!/usr/bin/env bash
# release.sh – neue Version von netbird-steamdeck.sh signieren und veröffentlichen.
# Die Decks übernehmen sie beim nächsten Update-Lauf (Timer: 3 min nach dem Start, dann alle 6 h).
#
#   ./release.sh            # Version setzen, prüfen, signieren, committen, pushen
#
# Signier-Schlüssel: ~/.ssh/steamdeck-netbird-signing (oder SIGNING_KEY=...).
# Der passende öffentliche Schlüssel steht als SIGNER_KEY im Skript. Ein neuer
# Schlüssel muss also erst mit einer Version, die noch mit dem alten signiert ist,
# auf die Decks.

set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

F=netbird-steamdeck.sh
NS=netbird-steamdeck
KEY=${SIGNING_KEY:-$HOME/.ssh/steamdeck-netbird-signing}

[[ -f $KEY ]] || { echo "Signier-Schlüssel fehlt: $KEY" >&2; exit 1; }

# Version = Zeitstempel, immer größer als die vorige
old=$(sed -n 's/^SCRIPT_VERSION=\([0-9]\{12\}\)$/\1/p' "$F")
[[ -n $old ]] || { echo "Keine Zeile SCRIPT_VERSION=JJJJMMTTHHMM in $F" >&2; exit 1; }
ver=$(date +%Y%m%d%H%M)
(( ver > old )) || ver=$((old + 1))
sed -i -E "s/^SCRIPT_VERSION=[0-9]{12}$/SCRIPT_VERSION=$ver/" "$F"

bash -n "$F"
if command -v shellcheck >/dev/null; then shellcheck "$F"; fi

# Signieren und genau so prüfen, wie es das Deck tut (mit dem Schlüssel aus dem Skript)
rm -f "$F.sig"
ssh-keygen -Y sign -q -f "$KEY" -n "$NS" "$F"
pub=$(sed -n 's/^SIGNER_KEY="\(.*\)"$/\1/p' "$F")
allowed=$(mktemp)
trap 'rm -f "$allowed"' EXIT
printf 'netbird-steamdeck namespaces="%s" %s\n' "$NS" "$pub" > "$allowed"
ssh-keygen -Y verify -f "$allowed" -I netbird-steamdeck -n "$NS" -s "$F.sig" < "$F" >/dev/null \
  || { echo "Signatur passt nicht zu SIGNER_KEY im Skript – nichts veröffentlicht." >&2; exit 1; }

git add -A
git commit -q -m "netbird-steamdeck.sh $ver"
git push -q -u origin main
echo "Veröffentlicht: $ver"

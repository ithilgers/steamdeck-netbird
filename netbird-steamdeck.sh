#!/usr/bin/env bash
# netbird-steamdeck.sh – NetBird auf SteamOS (Steam Deck) einrichten:
# installieren, per Setup-Key verbinden, NetBird-SSH einschalten, dauerhaft
# verbunden halten und automatisch aktualisieren (NetBird und dieses Skript).
#
# Neues Deck (Desktop-Modus → Konsole):
#   curl -fsSLO https://raw.githubusercontent.com/ithilgers/steamdeck-netbird/main/netbird-steamdeck.sh
#   bash netbird-steamdeck.sh                      # fragt nach dem Setup-Key
#   bash netbird-steamdeck.sh install SETUP-KEY    # Key gleich mitgeben
# Das Skript legt bei Bedarf erst ein Passwort für "deck" an (sudo braucht eins),
# fragt nach dem sudo-Passwort und dem Setup-Key – mehr ist nicht nötig.
#
# Weitere Aufrufe (ohne sudo, das Skript holt sich die Rechte selbst):
#   bash netbird-steamdeck.sh install [SETUP-KEY]  # installieren / reparieren (Standard)
#   bash netbird-steamdeck.sh update               # läuft automatisch alle 6 h + nach dem Start
#   bash netbird-steamdeck.sh uninstall            # alles wieder entfernen
#
# Warum so: SteamOS überschreibt bei Updates das System (/usr) und behält
# Änderungen in /etc nur, wenn sie in /etc/atomic-update.conf.d stehen.
# Deshalb liegt das NetBird-Binary unter /home/.netbird (überlebt Updates),
# und alle Dateien in /etc werden in die Behalten-Liste eingetragen.
#
# Selbst-Update: "update" holt die neueste Fassung dieses Skripts aus dem Repo und
# ersetzt sich nur, wenn die Signatur (.sig) zum Schlüssel unten passt und die
# Version höher ist. Neue Versionen werden mit release.sh signiert.

set -euo pipefail

# Wird von release.sh gesetzt (JJJJMMTTHHMM)
SCRIPT_VERSION=202611202039
SCRIPT_URL=https://raw.githubusercontent.com/ithilgers/steamdeck-netbird/main/netbird-steamdeck.sh
SIGNER_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGAQXUYaMEMIUfoZLuf9xL2I/WPLyGjshnL05xIrsjmE steamdeck-netbird release"
SIG_NAMESPACE=netbird-steamdeck

BASE=/home/.netbird
BIN_DIR="$BASE/bin"
BIN="$BIN_DIR/netbird"
SELF="$BASE/netbird-steamdeck.sh"
UNIT_DIR=/etc/systemd/system
DROPIN_DIR="$UNIT_DIR/netbird.service.d"
KEEP_FILE=/etc/atomic-update.conf.d/netbird.conf
PROFILE_FILE=/etc/profile.d/netbird.sh
SOCK=/var/run/netbird.sock
REPO=netbirdio/netbird
# NetBird-SSH-Server am Deck erlauben, Login auch als root (bleibt in der NetBird-Config gespeichert)
SSH_FLAGS=(--allow-server-ssh --enable-ssh-root)
TMP=""

log() { echo "[netbird-steamdeck] $*"; }
die() { echo "[netbird-steamdeck] FEHLER: $*" >&2; exit 1; }
cleanup() { [[ -n $TMP && -d $TMP ]] && rm -rf "$TMP"; return 0; }
trap cleanup EXIT

# Ohne root: bei Bedarf Passwort anlegen, dann mit sudo neu starten
if [[ $EUID -ne 0 ]]; then
  self=$(readlink -f "$0")
  [[ -f $self ]] || die "Bitte das Skript als Datei speichern und mit  bash <Datei>  starten."
  me=$(id -un)
  # Neues Deck: "deck" hat noch kein Passwort (Status NP), dann geht sudo nicht.
  if [[ $(passwd -S "$me" 2>/dev/null | awk '{print $2}') == NP ]]; then
    log "Für '$me' ist noch kein Passwort gesetzt, sudo braucht aber eins. Bitte jetzt festlegen:"
    passwd || die "Passwort wurde nicht gesetzt."
  fi
  log "Root-Rechte nötig – bitte das Passwort von '$me' eingeben."
  exec sudo bash "$self" "$@"
fi

[[ $(uname -m) == x86_64 ]] || die "Nur x86_64 (Steam Deck) wird unterstützt."

CURL=(curl -fsSL --retry 3 --retry-delay 5 --retry-all-errors --connect-timeout 15)

# Neueste Version über den Redirect von /releases/latest ermitteln (kein jq nötig)
latest_version() {
  local url tag=""
  if url=$("${CURL[@]}" -I -o /dev/null -w '%{url_effective}' \
           "https://github.com/$REPO/releases/latest" 2>/dev/null); then
    tag=${url##*/}
  fi
  # Fallback: GitHub-API
  if [[ ! $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    tag=$("${CURL[@]}" "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null \
          | grep -m1 '"tag_name"' | sed -E 's/.*"(v[^"]+)".*/\1/') || true
  fi
  [[ $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  echo "${tag#v}"
}

installed_version() {
  if [[ -x $BIN ]]; then
    "$BIN" version 2>/dev/null | head -n1 | tr -d 'v[:space:]' || true
  fi
}

# true, wenn $1 >= $2
version_ge() {
  [[ -n $1 ]] || return 1
  [[ $(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1) == "$1" ]]
}

download_and_install() {
  local ver=$1
  local name="netbird_${ver}_linux_amd64.tar.gz"
  local url="https://github.com/$REPO/releases/download/v${ver}"
  TMP=$(mktemp -d)

  log "Lade NetBird $ver …"
  "${CURL[@]}" -o "$TMP/$name" "$url/$name" || die "Download fehlgeschlagen: $name"

  if "${CURL[@]}" -o "$TMP/checksums.txt" "$url/netbird_${ver}_checksums.txt" 2>/dev/null; then
    (cd "$TMP" && grep " ${name}\$" checksums.txt | sha256sum -c --status) \
      || die "Prüfsumme stimmt nicht – Update abgebrochen."
    log "Prüfsumme ok."
  else
    log "Warnung: keine Prüfsummendatei gefunden, Prüfung übersprungen."
  fi

  mkdir -p "$TMP/x"
  tar -xzf "$TMP/$name" -C "$TMP/x" || die "Entpacken fehlgeschlagen."
  [[ -f $TMP/x/netbird ]] || die "Kein netbird-Binary im Archiv gefunden."
  "$TMP/x/netbird" version >/dev/null 2>&1 || die "Neues Binary startet nicht – Update abgebrochen."

  install -d -m 0755 -o root -g root "$BIN_DIR"
  install -m 0755 -o root -g root "$TMP/x/netbird" "$BIN.new"
  mv -f "$BIN.new" "$BIN"
  cleanup; TMP=""
  log "NetBird $ver installiert."
}

write_units() {
  # Offiziellen Dienst anlegen (bzw. neu anlegen, falls er auf ein anderes Binary zeigt)
  if [[ ! -f $UNIT_DIR/netbird.service ]] || ! grep -q "$BIN" "$UNIT_DIR/netbird.service"; then
    systemctl stop netbird 2>/dev/null || true
    "$BIN" service uninstall >/dev/null 2>&1 || true
    "$BIN" service install
  fi

  # Immer neu starten, nie aufgeben, erst nach /home und Netzwerk starten
  install -d -m 0755 "$DROPIN_DIR"
  cat > "$DROPIN_DIR/steamdeck.conf" <<EOF
[Unit]
RequiresMountsFor=$BASE
Wants=network-online.target
After=network-online.target
StartLimitIntervalSec=0

[Service]
Restart=always
RestartSec=10
EOF

  cat > "$UNIT_DIR/netbird-update.service" <<EOF
[Unit]
Description=NetBird auf die neueste Version aktualisieren
Wants=network-online.target
After=network-online.target
RequiresMountsFor=$BASE

[Service]
Type=oneshot
ExecStart=/usr/bin/bash $SELF update
EOF

  cat > "$UNIT_DIR/netbird-update.timer" <<'EOF'
[Unit]
Description=Regelmäßige NetBird-Update-Prüfung

[Timer]
OnBootSec=3min
OnCalendar=*-*-* 00/6:00:00
RandomizedDelaySec=10min
Persistent=true

[Install]
WantedBy=timers.target
EOF

  # Dateien in /etc, die SteamOS bei Updates behalten soll
  # (/etc/netbird: falls NetBird dort Config/Schlüssel ablegt; SteamOS liefert dort nichts aus)
  install -d -m 0755 /etc/atomic-update.conf.d
  cat > "$KEEP_FILE" <<EOF
$UNIT_DIR/netbird.service
$DROPIN_DIR/steamdeck.conf
$UNIT_DIR/multi-user.target.wants/netbird.service
$UNIT_DIR/netbird-update.service
$UNIT_DIR/netbird-update.timer
$UNIT_DIR/timers.target.wants/netbird-update.timer
/etc/netbird/**
$PROFILE_FILE
$KEEP_FILE
EOF

  # "netbird" im Terminal verfügbar machen
  echo "export PATH=\"\$PATH:$BIN_DIR\"" > "$PROFILE_FILE"
  ln -sf "$BIN" /usr/local/bin/netbird 2>/dev/null || true

  systemctl daemon-reload
}

ensure_running() {
  [[ -f $UNIT_DIR/netbird.service ]] || write_units
  systemctl is-enabled --quiet netbird || systemctl enable netbird
  systemctl is-active  --quiet netbird || systemctl start netbird
  systemctl is-enabled --quiet netbird-update.timer || systemctl enable --now netbird-update.timer
}

wait_for_daemon() {
  for _ in {1..30}; do
    [[ -S $SOCK ]] && return 0
    sleep 1
  done
  die "Der NetBird-Dienst startet nicht. Details:  journalctl -u netbird -n 50"
}

# Wartet, bis der Dienst weiß, ob er schon angemeldet ist (nach einem Start dauert das
# ein paar Sekunden). Ausgabe: connected | needslogin | unknown
login_state() {
  local out
  for _ in {1..45}; do
    out=$("$BIN" status 2>&1 || true)
    if grep -q "Management: Connected" <<<"$out"; then echo connected; return; fi
    if grep -qE "NeedsLogin|LoginFailed" <<<"$out"; then echo needslogin; return; fi
    sleep 1
  done
  echo unknown
}

ssh_enabled()    { "$BIN" status 2>/dev/null | grep -q "SSH Server: Enabled"; }
daemon_version() { "$BIN" status 2>/dev/null | sed -n 's/^Daemon version: *//p'; }

# Mit Setup-Key anmelden; bis zu 3 Versuche, falls der Key falsch eingegeben wurde
connect_with_key() {
  local key=${1:-}
  for _ in 1 2 3; do
    if [[ -z $key ]]; then
      [[ -t 0 ]] || die "Kein Terminal zum Eingeben – Key als Argument übergeben:  bash $SELF install <SETUP-KEY>"
      read -rp "NetBird-Setup-Key einfügen: " key
      key=${key//[[:space:]]/}
      [[ -n $key ]] || continue
    fi
    if "$BIN" up --setup-key "$key" "${SSH_FLAGS[@]}"; then
      return 0
    fi
    log "Anmeldung fehlgeschlagen. Ist der Key richtig, nicht abgelaufen und noch nicht verbraucht?"
    key=""
  done
  die "Keine Verbindung mit dem Setup-Key möglich."
}

show_summary() {
  local fqdn
  fqdn=$("$BIN" status 2>/dev/null | sed -n 's/^FQDN: *//p')
  echo
  "$BIN" status 2>/dev/null | grep -E '^(Management|FQDN|NetBird IP|SSH Server):' || true
  echo
  log "Fertig. NetBird startet ab jetzt mit dem Deck und aktualisiert sich selbst (netbird-update.timer)."
  log "Einmalig im NetBird-Dashboard (https://app.netbird.io → Peers → ${fqdn%%.*}):"
  log "  - \"SSH Access\" einschalten – ohne das lässt der Peer kein NetBird-SSH zu."
  log "  - Prüfen, dass der Peer in der Gruppe der SSH-Policy ist (vergibt der Setup-Key"
  log "    die Gruppe automatisch, ist das schon erledigt)."
  log "Danach vom PC aus:  ssh deck@${fqdn:-<FQDN>}"
}

do_install() {
  install -d -m 0755 -o root -g root "$BASE" "$BIN_DIR"

  local latest current updated=0
  latest=$(latest_version) || die "Konnte die neueste Version nicht ermitteln (Internet?)."
  current=$(installed_version)
  if version_ge "$current" "$latest"; then
    log "NetBird $current ist bereits aktuell."
  else
    download_and_install "$latest"
    updated=1
  fi

  # Skript selbst ablegen, damit der Update-Timer es findet
  if [[ $(readlink -f "$0") != "$SELF" ]]; then
    install -m 0755 -o root -g root "$0" "$SELF"
  fi

  apply_units
  systemctl enable netbird
  if (( updated )); then
    systemctl restart netbird   # sonst läuft weiter das alte Binary
  else
    systemctl start netbird
  fi
  systemctl enable --now netbird-update.timer
  wait_for_daemon

  if [[ $(login_state) == connected ]]; then
    log "NetBird ist bereits verbunden."
    if ! ssh_enabled; then
      log "Schalte den NetBird-SSH-Server ein (kurz getrennt) …"
      "$BIN" down >/dev/null 2>&1 || true
      "$BIN" up "${SSH_FLAGS[@]}"
    fi
  else
    connect_with_key "${1:-}"
  fi

  show_summary
}

# Dienst-Dateien schreiben und merken, mit welcher Skript-Version das passiert ist
apply_units() {
  write_units
  echo "$SCRIPT_VERSION" > "$BASE/.script-version"
}

# true, wenn Datei $1 mit Signatur $2 vom Schlüssel SIGNER_KEY signiert ist
signature_ok() {
  local allowed rc=0
  allowed=$(mktemp)
  printf 'netbird-steamdeck namespaces="%s" %s\n' "$SIG_NAMESPACE" "$SIGNER_KEY" > "$allowed"
  ssh-keygen -Y verify -f "$allowed" -I netbird-steamdeck -n "$SIG_NAMESPACE" \
    -s "$2" < "$1" >/dev/null 2>&1 || rc=1
  rm -f "$allowed"
  return $rc
}

# Neuere, gültig signierte Fassung dieses Skripts holen und $SELF ersetzen.
# Rückgabe 0 = ersetzt, sonst 1 (nichts Neues oder Fehler – dann bleibt alles, wie es ist).
self_update() {
  local dir new_ver
  dir=$(mktemp -d)
  if ! "${CURL[@]}" -o "$dir/script" "$SCRIPT_URL" 2>/dev/null \
     || ! "${CURL[@]}" -o "$dir/script.sig" "$SCRIPT_URL.sig" 2>/dev/null; then
    log "Skript-Update: Download fehlgeschlagen – später erneut."
    rm -rf "$dir"; return 1
  fi
  new_ver=$(sed -n 's/^SCRIPT_VERSION=\([0-9]\{12\}\)$/\1/p' "$dir/script" | head -n1)
  if [[ -z $new_ver ]] || (( new_ver <= SCRIPT_VERSION )); then
    log "Skript aktuell ($SCRIPT_VERSION)."
    rm -rf "$dir"; return 1
  fi
  if ! signature_ok "$dir/script" "$dir/script.sig"; then
    log "Skript-Update $new_ver: Signatur ungültig – NICHT übernommen."
    rm -rf "$dir"; return 1
  fi
  if ! bash -n "$dir/script"; then
    log "Skript-Update $new_ver: Syntaxfehler – nicht übernommen."
    rm -rf "$dir"; return 1
  fi
  install -m 0755 -o root -g root "$dir/script" "$SELF.new"
  mv -f "$SELF.new" "$SELF"
  rm -rf "$dir"
  log "Skript aktualisiert: $SCRIPT_VERSION → $new_ver"
  return 0
}

do_update() {
  # Erst das Skript selbst, dann mit der neuen Fassung weitermachen
  if [[ -z ${NB_SELF_UPDATED:-} ]] && self_update; then
    exec env NB_SELF_UPDATED=1 bash "$SELF" update
  fi
  # Nach einem Skript-Update die Dienst-Dateien neu schreiben (falls sie sich geändert haben)
  if [[ $(cat "$BASE/.script-version" 2>/dev/null) != "$SCRIPT_VERSION" ]]; then
    apply_units
  fi

  local latest current
  if ! latest=$(latest_version); then
    log "Neueste Version nicht ermittelbar (offline?) – später erneut."
    ensure_running
    exit 0
  fi
  current=$(installed_version)
  local running
  running=$(daemon_version)
  if version_ge "$current" "$latest"; then
    log "Aktuell ($current)."
    # Binary neuer als der laufende Dienst (z. B. nach install ohne Neustart)
    if [[ -n $running && $running != "$current" ]]; then
      log "Dienst läuft noch mit $running – Neustart auf $current."
      systemctl restart netbird
    fi
  else
    log "Update ${current:-keine} → $latest"
    download_and_install "$latest"
    systemctl restart netbird
  fi
  ensure_running
}

do_uninstall() {
  systemctl disable --now netbird-update.timer 2>/dev/null || true
  if [[ -x $BIN ]]; then
    "$BIN" service stop 2>/dev/null || true
    "$BIN" service uninstall 2>/dev/null || true
  fi
  rm -f "$UNIT_DIR/netbird-update.service" "$UNIT_DIR/netbird-update.timer"
  rm -rf "$DROPIN_DIR"
  rm -f "$KEEP_FILE" "$PROFILE_FILE"
  [[ -L /usr/local/bin/netbird ]] && rm -f /usr/local/bin/netbird
  systemctl daemon-reload
  rm -rf "$BASE"
  log "NetBird entfernt. (Peer-Daten unter /var/lib/netbird wurden nicht gelöscht.)"
}

case "${1:-install}" in
  install)   do_install "${2:-}" ;;
  update)    do_update ;;
  uninstall) do_uninstall ;;
  *) echo "Nutzung: bash $0 [install [SETUP-KEY]|update|uninstall]"; exit 1 ;;
esac

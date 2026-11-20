# steamdeck-netbird

Richtet [NetBird](https://netbird.io) auf einem Steam Deck (SteamOS) ein und hält es aktuell.

- installiert den NetBird-Client unter `/home/.netbird` (übersteht SteamOS-Updates)
- verbindet das Deck per Setup-Key
- schaltet den NetBird-SSH-Server ein (Login auch als `root`)
- startet NetBird mit dem Deck und startet es neu, falls es abstürzt
- aktualisiert NetBird und sich selbst automatisch (Timer: 3 min nach dem Start, dann alle 6 h)
- trägt alle Dateien in `/etc` in die Liste ein, die SteamOS bei Updates behält

## Neues Deck

Im Desktop-Modus die Konsole öffnen:

```bash
curl -fsSLO https://raw.githubusercontent.com/ithilgers/steamdeck-netbird/main/netbird-steamdeck.sh
bash netbird-steamdeck.sh
```

Das Skript legt bei Bedarf ein Passwort für `deck` an (sudo braucht eins), fragt nach dem
sudo-Passwort und dem Setup-Key.

Im NetBird-Dashboard:

1. Vorher einen Setup-Key anlegen. Am besten mit einer Auto-Gruppe, die in der SSH-Policy steht,
   dann ist das Deck gleich freigegeben.
2. Danach beim neuen Peer **SSH Access** einschalten. Ohne das lässt der Peer kein NetBird-SSH zu.

## Weitere Aufrufe

```bash
bash /home/.netbird/netbird-steamdeck.sh install [SETUP-KEY]   # reparieren / neu einrichten
bash /home/.netbird/netbird-steamdeck.sh update                # läuft sonst automatisch
bash /home/.netbird/netbird-steamdeck.sh uninstall             # alles entfernen
```

Status: `systemctl status netbird netbird-update.timer`, Log der Updates:
`journalctl -u netbird-update.service`.

## Selbst-Update

Bei jedem Update-Lauf lädt das Skript `netbird-steamdeck.sh` und `netbird-steamdeck.sh.sig` aus
diesem Repo. Es ersetzt sich nur, wenn

- die Version (`SCRIPT_VERSION`) höher ist als die installierte und
- die Signatur zum Schlüssel `SIGNER_KEY` im **installierten** Skript passt.

Eine Änderung am Repo ohne den privaten Signier-Schlüssel wird also nicht übernommen.

Neue Version veröffentlichen: `./release.sh`. Das Skript setzt die Version, prüft mit `bash -n` und
`shellcheck`, signiert mit `ssh-keygen -Y sign` und pusht.

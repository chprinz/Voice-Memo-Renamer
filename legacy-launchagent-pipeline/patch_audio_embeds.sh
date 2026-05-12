#!/bin/bash
# patch_audio_embeds.sh
# EINMALIG: Findet m4a im JPR-Ordner, verschiebt sie in den Vault,
# patcht Monthly Notes mit ![[filename.m4a]] unter dem passenden Heading.

JPR_DIR="/Users/christian/Library/Mobile Documents/iCloud~com~openplanetsoftware~just-press-record/Documents"
VAULT_AUDIO="/Users/christian/Library/Mobile Documents/iCloud~md~obsidian/Documents/Notes/🖋️ Journal/Audio"
JOURNAL_DIR="/Users/christian/Library/Mobile Documents/iCloud~md~obsidian/Documents/Notes/🖋️ Journal"

mkdir -p "$VAULT_AUDIO"

patched=0
moved=0
skipped=0

find "$JPR_DIR" -name "*.m4a" | sort | while IFS= read -r m4a; do
    filename=$(basename "$m4a")          # 19-13-53.m4a
    date=$(basename "$(dirname "$m4a")") # 2026-03-15
    time="${filename:0:5}"               # 19-13
    time_colon="${time/-/:}"             # 19:13
    month="${date:0:7}"                  # 2026-03

    # Zieldateiname mit Datum für Vault (eindeutig und sortierbar)
    dest_name="${date}_${time}_JPR.m4a"
    dest="$VAULT_AUDIO/$dest_name"

    # m4a verschieben falls noch nicht vorhanden
    if [[ ! -f "$dest" ]]; then
        cp "$m4a" "$dest"
        echo "Kopiert: $dest_name"
        ((moved++))
    else
        echo "Bereits vorhanden: $dest_name"
    fi

    # Monthly Note patchen
    note="$JOURNAL_DIR/${month}.md"
    if [[ ! -f "$note" ]]; then
        echo "Keine Monthly Note: ${month}.md"
        ((skipped++))
        continue
    fi

    heading="## ${date} ${time_colon}"
    embed="![[${dest_name}]]"

    if grep -qF "$heading" "$note" && ! grep -qF "$embed" "$note"; then
        python3 -c "
import sys
heading = sys.argv[1]
embed   = sys.argv[2]
path    = sys.argv[3]
with open(path, 'r') as f:
    content = f.read()
new_content = content.replace(heading + '\n', heading + '\n' + embed + '\n', 1)
with open(path, 'w') as f:
    f.write(new_content)
" "$heading" "$embed" "$note" \
        && echo "Gepatcht: $heading in ${month}.md" \
        && ((patched++)) \
        || echo "Fehler beim Patchen: $heading"
    else
        echo "Übersprungen (nicht gefunden oder bereits gepatcht): $heading"
        ((skipped++))
    fi
done

echo ""
echo "Fertig: $moved kopiert, $patched gepatcht, $skipped übersprungen"

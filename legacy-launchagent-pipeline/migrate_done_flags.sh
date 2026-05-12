#!/bin/bash
# migrate_done_flags.sh
# EINMALIG ausführen vor dem ersten Start von transcribe_catchup.sh.
# Legt .done-Dateien für alle m4a an, die bereits ein Transcript in der INBOX haben.

JPR_DIR="/Users/christian/Library/Mobile Documents/iCloud~com~openplanetsoftware~just-press-record/Documents"
VOICE_INBOX="/Users/christian/Library/Mobile Documents/iCloud~md~obsidian/Documents/Notes/📮INBOX/📻 VOICE INBOX"

created=0
skipped=0
no_match=0

find "$JPR_DIR" -name "*.m4a" | while IFS= read -r audio_file; do
    done_file="${audio_file%.m4a}.done"

    # Bereits vorhanden - überspringen
    if [[ -f "$done_file" ]]; then
        ((skipped++))
        continue
    fi

    # Datum und Uhrzeit aus Pfad ableiten
    # Struktur: JPR_DIR/YYYY-MM-DD/HH-MM-SS.m4a
    date_folder=$(basename "$(dirname "$audio_file")")   # z.B. 2026-03-11
    filename=$(basename "$audio_file" .m4a)              # z.B. 10-00-00
    hhmm="${filename:0:5}"                               # z.B. 10-00

    # Entsprechende Datei in INBOX suchen: YYYY-MM-DD_HH-MM_*.{md,txt}
    match=$(find "$VOICE_INBOX" -maxdepth 1 \
        \( -name "${date_folder}_${hhmm}_*.md" -o -name "${date_folder}_${hhmm}_*.txt" \) \
        | head -1)

    if [[ -n "$match" ]]; then
        touch "$done_file"
        echo "  .done gesetzt: $(basename "$audio_file")  →  $(basename "$match")"
        ((created++))
    else
        echo "  Kein Match:    $(basename "$audio_file")  (wird beim Start neu geprüft)"
        ((no_match++))
    fi
done

echo ""
echo "Fertig: $created .done gesetzt, $skipped bereits vorhanden, $no_match ohne Match"

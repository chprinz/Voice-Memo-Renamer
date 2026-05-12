#!/bin/bash
# transcribe_catchup.sh
# Pfad: /Users/christian/Library/Scripts/transcribe_catchup.sh

JPR_DIR="/Users/christian/Library/Mobile Documents/iCloud~com~openplanetsoftware~just-press-record/Documents"
VOICE_INBOX="/Users/christian/Library/Mobile Documents/iCloud~md~obsidian/Documents/Notes/📮INBOX/📻 VOICE INBOX"
VAULT_AUDIO="/Users/christian/Library/Mobile Documents/iCloud~md~obsidian/Documents/Notes/🖋️ Journal/Audio"
LMSTUDIO_URL="http://localhost:1234/v1"
LOG_FILE="/Users/christian/Library/Logs/transcribe_catchup.log"
LOCK_FILE="/tmp/transcribe_catchup.lock"

# ── Nur eine Instanz gleichzeitig ───────────────────────────────────────────
if [[ -f "$LOCK_FILE" ]]; then
    old_pid=$(cat "$LOCK_FILE")
    if kill -0 "$old_pid" 2>/dev/null; then
        exit 0  # Vorherige Instanz läuft noch, ruhig beenden
    fi
fi
echo $$ > "$LOCK_FILE"
trap "rm -f '$LOCK_FILE'" EXIT

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# ── LM Studio: geladenes Modell abfragen ────────────────────────────────────
get_loaded_model() {
    local models
    models=$(curl -s --max-time 5 "$LMSTUDIO_URL/models" 2>/dev/null)
    [[ -z "$models" ]] && echo "" && return
    python3 -c "
import json, sys
try:
    data = json.loads(sys.stdin.read())
    models = data.get('data', [])
    print(models[0]['id'] if models else '')
except:
    print('')
" <<< "$models"
}

# ── Slug via LM Studio ──────────────────────────────────────────────────────
get_slug() {
    local content="$1"
    local model="$2"

    local prompt="Du bekommst ein Voice-Memo Transkript. Antworte NUR mit einem JSON-Objekt, kein Text davor oder danach.

Erstelle einen beschreibenden Slug der Thema und Stimmung einfängt. So lang wie nötig, so kurz wie möglich – in der Regel 4-8 Wörter, aber wenn der Inhalt es braucht auch mehr. Konkret genug dass man in einem Jahr noch weiss worum es geht.

Regeln:
- Deutsch
- Kleinschreibung
- Nur Bindestriche, keine Sonderzeichen, keine Umlaute (ä→ae, ö→oe, ü→ue, ß→ss)
- Bei Tee-Verkostungen: Tee-Name plus Charakter, z.B. \"bao-mu-dan-blumig-leicht\"
- Keine generischen Wörter wie gedanken, reflexion, memo, notiz

Beispiele:
- \"morgenspaziergang-nebel-stille-dankbarkeit\"
- \"gespraech-mit-vater-versoehnung\"
- \"projektidee-dokumentarfilm-wasser\"

JSON Format:
{
  \"slug\": \"beispiel-langer-beschreibender-slug-hier\",
  \"short_slug\": \"beispiel-kurz\"
}

short_slug: die ersten 2-3 Wörter des slug, für Dateinamen.

Transkript:
${content:0:800}"

    local response
    response=$(curl -s --max-time 20 "$LMSTUDIO_URL/chat/completions" \
        -H "Content-Type: application/json" \
        -d "{
            \"model\": $(echo "$model" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().strip()))'),
            \"messages\": [
                {\"role\": \"system\", \"content\": \"You are a slug generator. Output ONLY valid JSON, no thinking, no explanation.\"},
                {\"role\": \"user\", \"content\": $(echo "$prompt" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')}
            ],
            \"temperature\": 0.1,
            \"max_tokens\": 200,
            \"enable_thinking\": false,
            \"stream\": false
        }" 2>/dev/null)

    [[ -z "$response" ]] && echo "" && return

    python3 -c "
import json, sys, re
try:
    data = json.loads(sys.stdin.read())
    text = data['choices'][0]['message']['content'].strip()
    match = re.search(r'\{.*?\}', text, re.DOTALL)
    if match:
        obj = json.loads(match.group())
        slug = obj.get('slug', '')
        short = obj.get('short_slug', '')
        if not short and slug:
            short = '-'.join(slug.split('-')[:3])
        print(slug + '|' + short)
    else:
        print('')
except:
    print('')
" <<< "$response"
}

# ── Loop 1: Neue Transcripts aus JPR → VOICE INBOX verschieben ──────────────
# Transcript-Dateien die noch nicht umbenannt wurden (kein YYYY- Präfix)
# → umbenennen und in INBOX verschieben
# → .done Sentinel neben der m4a anlegen
move_new_transcripts() {
    find "$JPR_DIR" \( -name "*.md" -o -name "*.txt" \) | while IFS= read -r file; do
        local filename
        filename=$(basename "$file")
        [[ "$filename" == [0-9][0-9][0-9][0-9]-* ]] && continue

        local content
        content=$(cat "$file" 2>/dev/null)
        [[ -z "$content" ]] && continue

        local date_folder time_part hhmm new_name
        date_folder=$(basename "$(dirname "$file")")
        time_part="${filename%.*}"
        hhmm="${time_part:0:5}"
        # Immer als .md, auch wenn Quelle .txt war
        new_name="${date_folder}_${hhmm}_JPR.md"

        mv "$file" "$VOICE_INBOX/$new_name" 2>/dev/null || continue
        log "Moved: $new_name"

        # Sentinel neben der m4a anlegen (gleicher Ordner, gleicher Basisname)
        local m4a_file
        m4a_file="$(dirname "$file")/${filename%.*}.m4a"
        if [[ -f "$m4a_file" ]]; then
            touch "${m4a_file%.m4a}.done"
        else
            # m4a noch nicht da (iCloud-Sync-Verzögerung) - Sentinel im Ordner merken
            touch "$(dirname "$file")/${filename%.*}.done"
        fi
    done
}

# ── Loop 2: Slugs nachholen ─────────────────────────────────────────────────
# Dateien in INBOX die noch kein Slug haben (exakt Format YYYY-MM-DD_HH-MM_JPR.ext)
add_slugs() {
    local model
    model=$(get_loaded_model)
    [[ -z "$model" ]] && return

    find "$VOICE_INBOX" -maxdepth 1 \( -name "*.md" -o -name "*.txt" \) \
    | grep -E "/[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}_JPR\.(md|txt)$" \
    | while IFS= read -r file; do
        local filename base datepart content result slug short_slug new_name
        filename=$(basename "$file")
        base="${filename%.*}"          # z.B. 2026-03-11_10-00_JPR
        datepart="${base%_JPR}"        # z.B. 2026-03-11_10-00

        content=$(cat "$file" 2>/dev/null)
        [[ -z "$content" ]] && continue

        result=$(get_slug "$content" "$model")
        [[ -z "$result" ]] && continue
        slug="${result%%|*}"
        short_slug="${result##*|}"
        [[ -z "$slug" ]] && continue

        # .md bekommt langen Slug
        new_name="${datepart}_${slug}_JPR.md"
        mv "$file" "$VOICE_INBOX/$new_name" 2>/dev/null \
            && log "Slug added: $new_name"

        # Audiodatei im Vault umbenennen (kurzer Slug, besser findbar)
        local audio_src="$VAULT_AUDIO/${datepart}_JPR.m4a"
        local audio_dest="$VAULT_AUDIO/${datepart}_${short_slug}_JPR.m4a"
        [[ -f "$audio_src" ]] && mv "$audio_src" "$audio_dest" 2>/dev/null \
            && log "Audio slug: $(basename "$audio_dest")"
    done
}

# ── Loop 3: Nicht transkribierte m4a nachholen ──────────────────────────────
# Prüfung: existiert .done neben der .m4a?
# .done wird in Loop 1 gesetzt - unabhängig davon ob .md später verschoben wird.
# Wenn .done fehlt: MacWhisper re-triggern (via touch), sofern es läuft.
# Wenn MacWhisper nicht läuft: nur loggen, beim nächsten Durchlauf nochmal.
catchup_untranscribed() {
    find "$JPR_DIR" -name "*.m4a" | while IFS= read -r audio_file; do
        local done_file="${audio_file%.m4a}.done"

        # .done vorhanden = bereits verarbeitet, egal wo die .md jetzt ist
        [[ -f "$done_file" ]] && continue

        # Transcript schon in INBOX? .done nachträglich setzen
        local date_folder
        date_folder=$(basename "$(dirname "$audio_file")")
        local hhmm
        hhmm=$(basename "$audio_file" .m4a | cut -c1-5)
        local inbox_match
        inbox_match=$(find "$VOICE_INBOX" -maxdepth 2             \( -name "${date_folder}_${hhmm}*.md" -o -name "${date_folder}_${hhmm}*.txt" \)             | head -1)
        if [[ -n "$inbox_match" ]]; then
            touch "$done_file"
            log ".done nachgesetzt (INBOX match): ${date_folder}/$(basename "$audio_file")"
            continue
        fi

        log "Ausstehend: ${date_folder}/$(basename "$audio_file")"

        if pgrep -x "MacWhisper" > /dev/null 2>&1; then
            # Datei kurz umbenennen und zurück – zwingt MacWhisper zur Neu-Erkennung
            local tmp_file="${audio_file%.m4a}_tmp.m4a"
            mv "$audio_file" "$tmp_file" 2>/dev/null
            sleep 1
            mv "$tmp_file" "$audio_file" 2>/dev/null
            log "MacWhisper re-trigger: ${date_folder}/$(basename "$audio_file")"
        else
            log "MacWhisper nicht aktiv - wartet auf naechsten Durchlauf"
        fi
    done
}

# ── Ausführen ────────────────────────────────────────────────────────────────
move_new_transcripts
add_slugs
catchup_untranscribed

#!/bin/bash
# install.sh
# Aus dem Projektordner ausführen:
# cd '/Users/christian/Dev Projects/JustPressRecord to Obsidian'
# bash install.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== JustPressRecord to Obsidian – Installation ==="
echo ""

# 1. Scripts-Ordner
mkdir -p ~/Library/Scripts
cp "$SCRIPT_DIR/transcribe_catchup.sh" ~/Library/Scripts/
chmod +x ~/Library/Scripts/transcribe_catchup.sh
echo "✓ transcribe_catchup.sh → ~/Library/Scripts/"

# 2. LaunchAgent
cp "$SCRIPT_DIR/com.littleprinz.transcribe-catchup.plist" ~/Library/LaunchAgents/
echo "✓ plist → ~/Library/LaunchAgents/"

# 3. Log-Ordner
mkdir -p ~/Library/Logs
echo "✓ ~/Library/Logs/ bereit"

# 4. Migration (bestehende m4a)
echo ""
echo "--- Bestehende Aufnahmen prüfen ---"
bash "$SCRIPT_DIR/migrate_done_flags.sh"

# 5. launchd laden (neu laden falls schon vorhanden)
launchctl unload ~/Library/LaunchAgents/com.littleprinz.transcribe-catchup.plist 2>/dev/null
launchctl load ~/Library/LaunchAgents/com.littleprinz.transcribe-catchup.plist
echo ""
echo "✓ launchd Job aktiv (alle 60s)"
echo ""
echo "=== Fertig ==="
echo ""
echo "Log beobachten:"
echo "  tail -f ~/Library/Logs/transcribe_catchup.log"

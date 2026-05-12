# JustPressRecord to Obsidian

Automatische Pipeline: Sprachaufnahmen vom iPhone landen transkribiert, benannt und eingebettet in Obsidian.

---

## Architektur

```
iPhone (Just Press Record)
  └── iCloud Drive
        └── JPR_DIR/YYYY-MM-DD/HH-MM-SS.m4a
              │
              │  MacWhisper (Watch Folder, läuft immer via Login Item)
              │  transkribiert .m4a → .md/.txt neben der Audiodatei
              │
              └── transcribe_catchup.sh (launchd, alle 60s)
                    │
                    ├── Loop 1: Neue Transcripts → VOICE INBOX
                    │   umbenennen: YYYY-MM-DD_HH-MM_JPR.md
                    │   .done Sentinel neben .m4a setzen
                    │
                    ├── Loop 2: Slugs nachholen (wenn LM Studio aktiv)
                    │   langer Slug → .md Dateiname
                    │   kurzer Slug (2-3 Wörter) → .m4a Dateiname im Vault
                    │
                    └── Loop 3: Catch-up
                        .done vorhanden? → skip
                        Transcript in INBOX? → .done nachsetzen
                        MacWhisper aktiv? → Datei umbenennen (re-trigger)

Manuell:
  VOICE INBOX
    └── gewünschte .md in Journal/ verschieben
          └── Templater: "Voice Memos eingliedern"
                ├── .md → Monthly Note (🖋️ Journal/YYYY-MM.md)
                ├── .m4a → Vault kopieren (🖋️ Journal/Audio/)
                │   einbetten als ![[...]]
                └── .md aus Journal/ löschen
```

---

## Pfade

| Was | Pfad |
|---|---|
| JPR iCloud-Ordner | `~/Library/Mobile Documents/iCloud~com~openplanetsoftware~just-press-record/Documents` |
| Voice Inbox | `📮INBOX/📻 VOICE INBOX/` |
| Journal-Staging | `📮INBOX/📻 VOICE INBOX/Journal/` |
| Audio im Vault | `🖋️ Journal/Audio/` |
| Monthly Notes | `🖋️ Journal/YYYY-MM.md` |
| Catch-up Script | `~/Library/Scripts/transcribe_catchup.sh` |
| launchd Job | `~/Library/LaunchAgents/com.littleprinz.transcribe-catchup.plist` |
| Log | `~/Library/Logs/transcribe_catchup.log` |

---

## Dateien im Projektordner

| Datei | Zweck | Wann ausführen |
|---|---|---|
| `install.sh` | Installiert Scripts, richtet launchd ein | Bei Erstinstallation und nach jeder Änderung an Scripts |
| `transcribe_catchup.sh` | Haupt-Script (Loop 1–3) | Automatisch via launchd alle 60s |
| `migrate_done_flags.sh` | Setzt .done für bereits verarbeitete Aufnahmen | Einmalig bei Erstinstallation |
| `com.littleprinz.transcribe-catchup.plist` | launchd Job-Definition | Wird von install.sh kopiert |
| `patch_audio_embeds.sh` | Audio-Embeds für bereits importierte Einträge nachpatchen | Einmalig, bereits erledigt |
| `fix_memo_linebreaks.py` | Segment-Zeilenumbrüche in Monthly Notes glätten | Einmalig nach Bulk-Import |
| `Voice Memos eingliedern.md` | Templater-Script für Journal-Integration | In Obsidian Templates-Ordner legen |

---

## Einmalige Installation

### 1. MacWhisper einrichten

**Login Item:** System Settings → General → Login Items → `+` → MacWhisper  
MacWhisper läuft damit immer im Hintergrund und verpasst keine Aufnahmen.

**Watch Folder:** MacWhisper → Settings → Watch Folder → JPR iCloud-Ordner, „Include subfolders" aktiv

**Modell:** Parakeet RNNT 1.1B (beste Qualität) oder Parakeet TDT 0.6B (schneller)

**Obsidian-Integration in MacWhisper: nicht aktivieren** – das Script routet nur JPR-Dateien. Andere Transkriptionen (YouTube etc.) landen so nicht im Vault.

### 2. Full Disk Access für bash

System Settings → Privacy & Security → Full Disk Access → `+` → `/bin/bash`  
Ohne das kann launchd nicht auf iCloud-Ordner zugreifen.

### 3. Scripts installieren

```bash
cd '/Users/christian/Dev Projects/JustPressRecord to Obsidian'
bash install.sh
```

Kopiert Scripts, führt Migration aus, aktiviert launchd.

### 4. Templater einrichten

`Voice Memos eingliedern.md` in den Obsidian Templates-Ordner legen.

Templater Settings → **Enable User System Command Functions** aktivieren  
Optional: Template Hotkeys → Hotkey direkt auf das Template legen.

---

## Täglicher Workflow

**Aufnahme machen** → Just Press Record öffnen, aufnehmen.

**Was automatisch passiert:**
1. MacWhisper transkribiert die .m4a sobald sie in iCloud erscheint
2. transcribe_catchup.sh erkennt das Transcript innerhalb von 60s, verschiebt es in die Voice Inbox und benennt es um: `YYYY-MM-DD_HH-MM_JPR.md`
3. Sobald LM Studio läuft, wird ein Slug nachgeholt: `YYYY-MM-DD_HH-MM_langer-beschreibender-slug_JPR.md`

**Ergebnis:** Fertige `.md` in `📮INBOX/📻 VOICE INBOX/`

**Voice Memos ins Journal eingliedern:**
1. Gewünschte `.md` manuell in `VOICE INBOX/Journal/` verschieben
2. Eine beliebige Note in Obsidian öffnen
3. Command Palette → Templater → `Voice Memos eingliedern`

---

## Format in den Monthly Notes

```markdown
## 2026-03-29 08:04
![[2026-03-29_08-04_JPR.m4a]]
**langer-beschreibender-slug**
Transkript als fließender Text ohne Leerzeilen...
```

---

## Betrieb & Debugging

```bash
# Log live beobachten
tail -f ~/Library/Logs/transcribe_catchup.log

# Script manuell testen
bash ~/Library/Scripts/transcribe_catchup.sh

# launchd Job neu starten (nach install.sh automatisch)
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.littleprinz.transcribe-catchup.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.littleprinz.transcribe-catchup.plist

# Läuft launchd? (- 0 = aktiv, Zahl = PID läuft gerade)
launchctl list | grep littleprinz
```

---

## Bekannte Einschränkungen

**Kein Append in JPR:** Just Press Record erlaubt kein Anhängen an bestehende Aufnahmen. Zweite Aufnahme am gleichen Tag erzeugt eine separate Datei.

**MacWhisper Catch-up:** Wenn MacWhisper beim iCloud-Sync nicht lief, erkennt Loop 3 die fehlenden Dateien und re-triggert via Umbenennung. Dauert bis zu 60s nach MacWhisper-Start.

**Audio-Originale bleiben im JPR-Ordner:** Das Templater-Script kopiert die .m4a in den Vault, löscht das Original nicht. JPR-Ordner kann manuell bereinigt werden.

**LM Studio optional:** Ohne aktives LM Studio landen Dateien ohne Slug in der Inbox (`YYYY-MM-DD_HH-MM_JPR.md`) und werden beim nächsten Durchlauf nachgeholt.

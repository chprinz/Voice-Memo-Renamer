#!/usr/bin/env python3
# fix_memo_linebreaks.py
# Einmalig: Joinst Segment-Zeilenumbrüche in Voice-Memo-Blöcken der Monthly Notes.
# Führt kein dry-run durch - macht vorher ein Backup.

import os
import re
import shutil
from pathlib import Path

JOURNAL_DIR = Path("/Users/christian/Library/Mobile Documents/iCloud~md~obsidian/Documents/Notes/🖋️ Journal")

def fix_note(path):
    text = path.read_text(encoding="utf-8")
    lines = text.split("\n")
    result = []
    i = 0

    while i < len(lines):
        line = lines[i]

        # Heading, Embed, Slug, Leerzeile → unverändert
        if (line.startswith("## ") or
            line.startswith("![[") or
            line.startswith("**") or
            line.strip() == ""):
            result.append(line)
            i += 1
            continue

        # Textzeilen sammeln und zu einem Absatz joinen
        para = []
        while i < len(lines):
            l = lines[i]
            if (l.startswith("## ") or
                l.startswith("![[") or
                l.startswith("**") or
                l.strip() == ""):
                break
            if l.strip():
                para.append(l.strip())
            i += 1

        if para:
            result.append(" ".join(para))

    return "\n".join(result)

notes = list(JOURNAL_DIR.glob("*.md"))
if not notes:
    print(f"Keine Monthly Notes gefunden in: {JOURNAL_DIR}")
    exit(1)

for note in sorted(notes):
    backup = note.with_suffix(".md.bak")
    shutil.copy2(note, backup)
    fixed = fix_note(note)
    note.write_text(fixed, encoding="utf-8")
    print(f"Fertig: {note.name}  (Backup: {backup.name})")

print(f"\n{len(notes)} Datei(en) verarbeitet. Backups liegen im gleichen Ordner.")
print("Backups löschen: find '", JOURNAL_DIR, "' -name '*.md.bak' -delete", sep="")

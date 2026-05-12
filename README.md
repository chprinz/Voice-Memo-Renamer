# Voice Memo Renamer

Native macOS SwiftUI V1 for importing personal voice memos into an Obsidian journal workflow.

## What V1 does

- Drag and drop `.m4a`, `.mp3`, and `.wav` audio files.
- Copies audio into an app-managed local history area.
- Runs MacWhisper CLI through `/usr/local/bin/mw`.
- Sends the transcript to LM Studio at `http://localhost:1234/v1`.
- Keeps visible local import history in `~/Library/Application Support/VoiceMemoRenamer/history.json`.
- Reviews title, summary, workflow, date, transcript, and technical details.
- Imports approved memos into the Obsidian monthly journal note and copies audio into `🖋️ Journal/Audio/`.

## Default workflow

The default destination is `Obsidian Journal`.

The exporter appends entries to:

```text
~/Library/Mobile Documents/iCloud~md~obsidian/Documents/Notes/🖋️ Journal/YYYY-MM.md
```

and copies audio to:

```text
~/Library/Mobile Documents/iCloud~md~obsidian/Documents/Notes/🖋️ Journal/Audio/
```

## Build

Use the Xcode app toolchain if Command Line Tools are selected:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
```

To build a launchable `.app` bundle with the current executable, plist, and app icon:

```bash
Scripts/build-app.sh
```

Run the app bundle:

```bash
open -n .build/VoiceMemoRenamer.app
```

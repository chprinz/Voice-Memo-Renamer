# Voice Memo Renamer

Voice Memo Renamer is a small native macOS app I built for my own voice-note workflow.

I often record quick thoughts, ideas, and spoken notes, then want them to end up in my Obsidian journal with useful filenames, a transcript, a short summary, and enough structure that I can find them again later. This app exists for that very specific need: take local audio files, transcribe them with MacWhisper, analyze the transcript with a local LM Studio model, and import the reviewed result into an Obsidian vault.

This is not a general-purpose transcription product yet. It is a personal workflow app that I am making public because it may be useful to others with a similar local-first setup, or as a starting point for their own version.

## Status

Version `1.2.0`. First public release was `1.0.0`.

The app currently assumes:

- macOS 13 or newer.
- MacWhisper CLI is installed and available at `/usr/local/bin/mw`.
- LM Studio is running a local OpenAI-compatible endpoint at `http://localhost:1234/v1`.
- You use Obsidian, or you configure one of the non-Obsidian workflows in the app settings.
- You are comfortable with a source-available, private-use project that was built around one person's workflow.

## Screenshots

Current queue with transcription analysis in progress:

![Voice Memo Renamer current queue with analysis in progress](docs/images/current-analysis.jpg)

History view with imported voice memos:

![Voice Memo Renamer history view with finished imports](docs/images/history-imported.jpg)

Settings for workflows, storage, MacWhisper, and LM Studio:

![Voice Memo Renamer settings view](docs/images/settings-workflows.jpg)

## What It Does

- Drag and drop audio: `.m4a`, `.m4b`, `.mp3`, `.wav`, `.wave`, `.w64`, `.aiff`, `.aif`, `.aifc`, `.caf`, `.flac`, `.aac`, `.opus`, `.ogg`, `.mp4`, `.mov`.
- Copies audio into an app-managed local processing area.
- Runs MacWhisper CLI for transcription.
- Sends the transcript to LM Studio for local metadata generation.
- Lets you review the title, summary, workflow, date, transcript, and technical details in a side panel, so you can move through several recordings without closing anything.
- Or skips analysis entirely per workflow, when a filename-based rename is all you need (see [Workflows Without Analysis](#workflows-without-analysis)).
- Imports approved memos into an Obsidian monthly journal note.
- Copies audio into the configured audio destination folder.
- Optionally compresses and/or loudness-normalizes the exported audio copy (see [Audio Processing Options](#audio-processing-options)).
- Keeps local import history in:

```text
~/Library/Application Support/VoiceMemoRenamer/history.json
```

## Default Workflow

The default destination is `Obsidian Journal`.

By default, the exporter appends entries to:

```text
~/Library/Mobile Documents/iCloud~md~obsidian/Documents/Notes/🖋️ Journal/YYYY-MM.md
```

and copies audio to:

```text
~/Library/Mobile Documents/iCloud~md~obsidian/Documents/Notes/🖋️ Journal/Audio/
```

You can change workflows, destination folders, watch folders, filename patterns, and transcript/audio behavior in the app settings.

## Workflows Without Analysis

Some recordings already carry their subject in the filename, and running them through
LM Studio only produces a worse name than the one you typed yourself. Each workflow
therefore has an **Analyze with LM Studio** switch under Settings → Workflows → Review & analysis.

With it off, the workflow transcribes and stops there. The title, slug, and filename
all come from the original filename, so importing takes as long as transcription and
nothing else. Pair it with a filename pattern built from `{date}` and `{filename}`:

```text
{date}_{filename}   →   2026-08-14_2012 Quanjihao Manzhuan.m4a
```

The two placeholders that reuse the original name are:

- `{filename}` — the original name, unchanged, so capitals and spaces survive.
- `{filenameSlug}` — the original name as a lowercase slug.

The pattern preview under the field shows a sample named `Original Filename.m4a`, so
you can see at a glance which part of the result comes from the source file. The full
placeholder list with explanations is behind the **?** button next to the preview.

Two more per-workflow switches control what the exported note looks like: whether it
starts with a bold title line, and whether the summary is written as one sentence,
as bullet points, or left out completely.

## Finding Things Again

Recordings are grouped by day — Today, Yesterday, then the date — in both Current and
History, and the search field above the list matches the title, the summary and the
full transcript. That is usually the fastest way back to a recording: search a word you
know you said.

Current also carries a filter — All / Needs you / Failed — so a queue with one stuck
import does not hide the rest.

## Temporary Copies

Audio dragged from an app that hands over data rather than a file is copied into the
app's own folder first. Settings → Services → Cache shows how much that folder holds,
and **Keep** decides when copies go: by default once the recording is imported, which
is also when a copy stops being needed. A copy is only ever deleted if the audio
verifiably exists somewhere else, so a workflow that leaves audio in place keeps its
copy.

## Dates Spoken In The Recording

File timestamps are frequently wrong, because copying or syncing a recording rewrites
them. When Settings → General has **Use a date spoken in the recording** enabled, a
date stated at the very beginning or end of a memo takes priority over the file's own
date. Only explicitly written out dates count (`14.08.2026`, `14. August 2026`,
`2026-08-14`, `August 14, 2026`), optionally with a clock time next to them.

Where the date came from is shown in the review panel under the date picker, and you
can always overrule it there.

## Audio Processing Options

Both live under Settings → Audio: **Normalize** and **Compress**. They're global — not per-workflow — since whether a file needs processing depends on the source audio, not the destination. They apply whenever the workflow handling an import actually produces an export copy (audio file behavior "Copy audio to folder" or "Move audio to folder"); workflows that leave audio in place or rename in place are unaffected. The original source file is never modified — only the exported copy is affected.

- **Normalize (-16 LUFS)**: two-pass EBU R128 loudness normalization (`ffmpeg`'s `loudnorm` filter, target -16 LUFS / -1.5 dBTP / LRA 11) at the source's own sample rate. It runs **before transcription**, because a quiet recording is harder for MacWhisper to read, and the same normalized copy is then reused for the exported audio — `loudnorm` never runs twice. Useful for recorders (e.g. wireless lav mics) whose raw levels vary a lot. Requires `ffmpeg`; its path is configurable under Settings → Services and defaults to `/opt/homebrew/bin/ffmpeg`, and with normalization on, a missing `ffmpeg` stops the import before transcription rather than after it.
- **Compress**: runs at export only, on the exported copy. re-encodes the exported copy to AAC/M4A at the source sample rate, via the built-in `afconvert`. Bitrate (32–256 kbps) and mono vs. source channels are set alongside it under Settings → Audio. M4A sources that are already below twice the target bitrate are left untouched to avoid a quality-losing second encode.

So the full order is: normalize → transcribe → analyze → review → compress → export. The
normalized copy lives in the processing cache and is deleted once the import succeeds.

Separately from all of this, audio in unusual sample formats — 32 bit float WAV from
wireless field recorders, for instance — is converted to plain 16 bit PCM in the cache
before transcription, and converted again as a retry if MacWhisper rejects a file. That
conversion only ever feeds the transcriber. With normalization on it is usually not
needed at all, since the normalized copy is already plain PCM.

## Privacy

The app is designed for a local-first workflow:

- Audio processing happens on your Mac.
- Transcription is performed by MacWhisper CLI.
- Transcript analysis is sent to your local LM Studio server.
- Import history and temporary processing files are stored locally in Application Support.

The app does not intentionally send audio or transcripts to a cloud service. If your Obsidian vault lives in iCloud Drive or another sync provider, those files are handled by that provider after export.

## Requirements

- macOS 13 or newer.
- Xcode app toolchain for building from source.
- MacWhisper CLI.
- LM Studio with a loaded local model.
- Optional: Obsidian with an existing vault.
- Optional: `ffmpeg` (only if you enable loudness normalization; with it on, imports need `ffmpeg` before they can be transcribed). Audio compression and format conversion use the built-in `afconvert`, no extra install needed.

## Run The Downloaded App

Download the latest DMG from [GitHub Releases](https://github.com/chprinz/Voice-Memo-Renamer/releases) and drag `Voice Memo Renamer.app` into Applications.

Because this app is currently distributed outside the Mac App Store and may not be notarized, macOS may show a security warning on first launch. If that happens, open it from Finder with Control-click, choose Open, and confirm that you want to run it.

Before importing files, open Settings and check:

- MacWhisper CLI path.
- LM Studio base URL.
- Loaded LM Studio model.
- Default workflow.
- Obsidian vault or destination folder paths.
- `ffmpeg` path, if you plan to enable loudness normalization on a workflow.

## Build From Source

Use the Xcode app toolchain if Command Line Tools are selected:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
```

To build a launchable `.app` bundle:

```bash
Scripts/build-app.sh
```

Run the app bundle:

```bash
open -n .build/VoiceMemoRenamer.app
```

## Build The Release DMG

To build a release app and package it as a DMG:

```bash
Scripts/build-dmg.sh 1.2.0
```

The DMG is written to:

```text
dist/VoiceMemoRenamer-1.2.0.dmg
```

This script uses ad-hoc signing for local distribution. For broader public distribution, use a Developer ID certificate and notarization.

## Known Limitations

- Only tested on my own setup.
- MacWhisper CLI is the only transcription backend right now.
- LM Studio is the only analysis backend right now.
- The default workflow is opinionated around Obsidian, iCloud Drive, and monthly journal notes.
- First-run setup is still manual.
- Import history is written to disk on the main thread, so very large histories will eventually feel sluggish.
- Public binary distribution is not yet a polished notarized installer flow.

## Future Ideas

- Optional Micro Whisper support.
- Additional transcription backends.
- Setup assistant for first launch.
- More reusable workflow templates.
- Signed and notarized public releases.

## License

This project is source-available for private use. See [LICENSE](LICENSE).

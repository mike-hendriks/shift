# Shift

Menu bar app for macOS that converts, compresses and resizes files the moment you drag them and hold Shift.
Results stay in a floating shelf, ready to drag into the next tool.

## How it works

1. Drag one or more files anywhere (Finder, desktop, any app that drags real files).
2. Hold **Shift** while dragging. A bar slides in across the full width of the screen, under the menu bar,
   with large tiles for the actions that fit what you are dragging.
3. Slide onto a tile and let go: it runs right away. Let go on "Op de shelf" to park the files as they are.
   Let go anywhere else on the bar and it stays open: click a tile or press 1-9 (Return runs the first).
4. Results land in the shelf (top right). Drag them out into Figma, a CMS, Slack, Mail, anything. Double-click opens, the copy button puts the file (and image data) on the clipboard.
   Click a row to select it, then **Space** opens Quick Look, the arrow keys move through the shelf, Delete takes the file off the shelf and ⌘C copies it.

No Accessibility or Input Monitoring permission needed: Shift polls mouse, modifier and drag-pasteboard state.

## Actions

| Files | Actions |
| --- | --- |
| Images | **Web preset** (WebP, max 2000 px long edge, quality 78, sRGB, metadata stripped), convert to JPG/PNG/WebP/AVIF (suggested per source format), compress, 50% / max 1920 / 1280 / 640 px, combine into one PDF, Markdown via OCR |
| Text (md, txt, docx, rtf, html, code) | PDF (A4, page numbers, Markdown rendered), Markdown (headings, lists, links, tables), plain text |
| PDF | Compress (images to JPEG at 144 dpi), Markdown (paragraphs rebuilt from line positions), pages to PNG or JPG |
| Video | Web 1080p / 720p (H.264 MP4, capped bitrate), MP4, extract audio, Markdown transcript |
| Audio | M4A, Markdown transcript |
| Anything else | Park on the shelf |

Transcripts run on-device (macOS 26). The language is detected by transcribing a 30 second sample in each of
your preferred languages and keeping the most confident one. Dutch goes through DictationTranscriber, which
covers languages SpeechTranscriber does not. The first run per language downloads the speech model.

Compression never ships a bigger file: if the result is larger, the original is kept.
Output goes to `~/Downloads/Shift` (change it from the menu bar icon).

## Requirements

- macOS 15 or later, Swift 6 toolchain (Command Line Tools are enough)
- `cwebp` for WebP output: `brew install webp`. Without it, the web preset falls back to JPG/PNG.

## Build

```bash
scripts/build-app.sh            # builds dist/Shift.app and dist/shift-cli
scripts/build-app.sh --install  # also copies to /Applications and launches
```

## CLI

The same engine is available from the terminal:

```bash
dist/shift-cli suggest photo.heic notes.md
dist/shift-cli web --out ~/Desktop/web *.jpg
```

## Layout

- `Sources/ShiftCore` - file detection, suggestions and all processing (ImageIO, cwebp, TextKit, PDFKit, AVFoundation)
- `Sources/Shift` - the app: drag watcher, drop panel, shelf, menu bar
- `Sources/ShiftCLI` - command line wrapper around ShiftCore

# Shift release film: storyboard

60 seconds, 1920×1080, 60 fps, cut to 120 BPM (one beat = 0.5 s). Copy in English, like the app.

| Time | Scene | What happens | Sound |
| --- | --- | --- | --- |
| 0.0–6.5 | The grind | Words hit on the beat: Export. Resize. Compress. Upload. Wait. Download. Rename. Too big. UI shards pile up (upload bar, "file too large", Export As, a file called final-v3-FINAL). "Every single time." Everything collapses into one point. | Ticking hats speeding up, glitch hits, riser, hard cut to silence |
| 6.5–12.0 | The turn | "There's a shorter way." A Shift keycap rises and gets pressed on the downbeat. The key folds into the app icon, the wordmark lands. "Drag. Hold Shift. Done." | Silence, then impact with shockwave, warm chord |
| 12.0–23.5 | Demo | Desktop. Drag a photo out of Finder, hold Shift, the bar slides in. Drop on Web preset. 8.4 MB becomes 412 KB on the shelf (−95%). Drag the result straight into a CMS. | Beat drops. Whoosh, clicks, pop on the shelf |
| 23.5–30.0 | Batch | Select five mixed files. The bar groups them by type. Press 1 instead of dropping. Shelf fills up. | Groove continues |
| 30.0–50.0 | Five USPs, 4 s each | Anything becomes Markdown (OCR, PDF, transcripts on-device, Dutch included). Smaller, never bigger. Tuned to how you work (presets, trigger keys). Nothing leaves your Mac. Also in your terminal, and it updates itself. | Groove, a hit per block |
| 50.0–54.0 | The wall | Every action tile streams past in 3D. "Every file. One key." | Riser |
| 54.0–60.0 | End card | Icon, Shift, "Drag. Hold Shift. Done." Free for macOS, github.com/mike-hendriks/shift, Made by Stuurmen. | Final impact, chord rings out |

## Build

```bash
cd promo
npm install
npm run build      # renders frames, generates the soundtrack, encodes shift-release.mp4
```

`index.html` is the whole film: `render(t)` draws the frame at time `t`, so every frame is deterministic.
Open it in Chrome with `#t=17.5` to inspect a moment, or `#play` to preview in real time (no sound).

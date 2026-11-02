# Halo

Drag a file anywhere in macOS, tap a modifier, drop it on a wheel.

| Tap while dragging | Wheel |
| --- | --- |
| ⇧ Shift | Conversion (images, documents, spreadsheets, audio, video, archives, subtitles) |
| ⌘ Cmd | Tools: Compress, Resize, Metadata; images also Edit, Crop, Redact, Annotate, Add BG; audio/video also Trim, Channels, Bleep |
| ⌃ Ctrl | Actions (AirDrop, Float, Copy, Move, Copy Path, Terminal) |

Drop on the hub to cancel. Modifiers can be changed in Settings.

## Build

```bash
xcodegen generate
xcodebuild -project Halo.xcodeproj -scheme Halo build
xcodebuild -project Halo.xcodeproj -scheme Halo test
```

Requires macOS 26+ (Liquid Glass). Distributed outside the App Store, so there is no sandbox.

## App icon

Designed in Canva. `scripts/make-icon.sh Vendor/icon-canva.png` finds the artwork in the Canva export, masks it onto the macOS icon grid (`Vendor/icon-master.png`) and rebuilds `Halo/Assets.xcassets/AppIcon.appiconset`.

## Engines

- Native: ImageIO, PDFKit, NSAttributedString and AppKit printing.
- **ffmpeg**: audio, video, WEBP/AVIF encoding. Put a *statically linked* binary at `Vendor/ffmpeg` to embed it in the app; otherwise a Homebrew ffmpeg is used. Homebrew's own ffmpeg is dynamically linked, so it cannot be copied into the app.
- **LibreOffice** (optional): PPT/PPTX, high-fidelity DOCX→PDF and all spreadsheet conversions. Formats that need a missing engine are hidden from the wheel.

## Architecture

- `Drag/DragMonitor`: global mouse monitors (no Accessibility permission needed) plus 60 Hz modifier polling, only while a file drag is active.
- `Wheel/`: non-activating panel, drop target hit-testing (`WheelGeometry`), SwiftUI drawing.
- `Model/Catalog`: the compatibility matrix, the single source of truth for the wheel, Settings and tests.
- `Engine/`: one engine per category, plus tools and quick actions.

## Status: phase 2

Image editors (`Editor/`) preview on a downscaled copy and re-apply the same normalized edit to the full-resolution image on Apply. Audio/video editors decode a 22 kHz stereo preview for the waveform and live playback (AVAudioEngine); Apply runs ffmpeg on the original. Video keeps its picture stream (`-c:v copy`) except for Trim, which re-encodes for frame accuracy. An editor opens for the first file of a multi-file drop.

Not yet built:
- Conversions to or from PAGES and EPUB, plus PDF→PPTX/XLSX.
- App icon.

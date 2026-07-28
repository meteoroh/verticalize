# Verticalize

Turn a landscape video into a vertical one that follows a person you pick.

A native macOS app. Import a clip, let it scan for everyone who appears, choose your
subject, and it renders a 9:16 crop that tracks them — smoothed like a camera operator
rather than snapped to a bounding box.

## How it works

```
decode ─► detect ─► describe ─► associate ─► smooth ─► compose ─► encode
 12fps    Vision    feature      identity     virtual   transform   H.264
 sample   humans    prints       tracking     camera    ramps       / HEVC
```

**Detection** — `DetectHumanRectanglesRequest` on frames sampled at 12fps, capped at
9000 frames so a long clip lowers its rate rather than scanning forever.

**Appearance** — `GenerateImageFeaturePrintRequest` over the head-and-torso crop,
computed only on frames where identity is actually contested.

**Association** — [`IdentityTracker`](verticalize/Services/IdentityTracker.swift) builds
one cost matrix per frame blending predicted motion with appearance and solves it
optimally with the Hungarian method. Appearance's weight rises from 0.35 to 0.8 when
people are in contact, which is when motion alone flips identities. Tracks coast on
prediction through occlusions, and only learn appearance from uncontested crops.

**Framing** — [`CropPath`](verticalize/Services/CropPath.swift) turns the subject's
sightings into a virtual camera: resample onto a uniform grid, smooth, then drive with a
deadzone and a speed cap so the shot locks off when the subject is still and pans when
they move.

**Render** — the moving crop becomes affine transform ramps on a video composition layer
instruction, so the preview player and the exporter produce identical frames on the
hardware path. Export goes through `AVAssetReader`/`AVAssetWriter` rather than
`AVAssetExportSession`, so the output is exactly the requested size instead of whatever a
preset decides.

No third-party dependencies and no bundled ML models — Apple frameworks only.

## Output

9:16 (1080×1920), 4:5, or 1:1. H.264 or HEVC, in `.mp4`, with the source audio
re-encoded to AAC.

## Controls

| | |
|---|---|
| Smoothing | Seconds of temporal averaging on the subject's position |
| Deadzone | How far the subject drifts before the camera moves at all |
| Pan speed | Ceiling on how fast the frame can travel |
| Zoom | 1.0× uses the full source height |
| Vertical bias | Nudges the subject up or down in frame when zoomed in |

## Requirements

macOS 26.5+, Xcode 26+.

```bash
git clone https://github.com/meteoroh/verticalize.git
cd verticalize
open verticalize.xcodeproj
```

Or from the command line:

```bash
xcodebuild -project verticalize.xcodeproj -scheme verticalize -configuration Release build
```

The project has a `DEVELOPMENT_TEAM` set for local signing. If you're building this
yourself, change it to your own team in the target's Signing & Capabilities.

## Known limitations

- **No shot-cut detection.** On edited footage the tracker will happily associate across
  a hard cut, and the camera pans across it instead of jumping. Fine for single takes.
- **Appearance uses a general-purpose embedding.** Vision's `FeaturePrint` is not trained
  for person re-identification, so two people dressed alike can still be confused. A
  dedicated ReID Core ML model is the biggest available quality lever.
- **Automated tests use synthetic input.** The tracking, geometry, and export layers are
  covered by scripted scenarios with known ground truth. Vision's detector and feature
  prints themselves are exercised only by running the app on real footage.

## Tuning

Most behaviour lives in two option structs, both worth adjusting against your own
footage:

- [`PersonScanner.Options`](verticalize/Services/PersonScanner.swift) — sample rate,
  analysis resolution, confidence floor, merge threshold.
- [`IdentityTracker.Options`](verticalize/Services/IdentityTracker.swift) — motion gating,
  appearance weights and ceiling, coast window.

If one person gets split into two cards, raise `appearanceCeiling`. If the crop follows
the wrong person after an overlap, raise `appearanceWeightAmbiguous`.

## License

MIT — see [LICENSE](LICENSE).

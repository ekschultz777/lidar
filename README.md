# lidar

An iOS app that captures **LiDAR scene depth** from a LiDAR-equipped iPhone or iPad and exports it as a quantitative depth image, with a live **plumb / upright level** so you can hold the phone square when measuring.

Requires a device with a LiDAR scanner (for example iPhone 16 Pro). Built with ARKit `sceneDepth` and Core Motion.

## What it does

- Live camera preview with a false-color overlay of depths inside an adjustable **Near / Far** window (about 5 cm–5 m).
- **Capture** saves:
  - a photo to the Photos library
  - a **Float32 TIFF** where each pixel is distance from the camera plane in **meters** (values outside Near/Far, and invalid samples, are `0`)
- Copies of the TIFF are also written under the app Documents folder for Files access.
- A **level bubble** in the corner shows how close the phone is to perfectly upright (portrait, plumb). It turns green only when tilt is essentially zero.

## Measurement accuracy

### LiDAR depth

Depth comes from ARKit’s LiDAR-backed scene depth map (`ARFrame.sceneDepth`), not from a separate ranging algorithm in this app. Each TIFF sample is stored as a 32-bit float in meters, so the **file can represent millimeter-scale values**, but that is storage precision—not a guarantee that every sample is that accurate in the real world.

In practice, for Pro / Pro Max class devices:

| Aspect | Expectation |
| --- | --- |
| Useful range | Roughly **0.25–5 m**; this app’s Near/Far controls span about **0.05–5.0 m** |
| Typical accuracy | Often **~1 cm or better** at close / mid range on matte surfaces; independent tests of iPhone LiDAR often report on the order of **~5 mm RMSE** in favorable conditions |
| Best results | Steady hold, diffuse surfaces, good lighting for the fused RGB+depth map, distances well inside the Far limit |
| Weaker results | Very reflective, transparent, or light-absorbing surfaces; edges and thin structures; longer ranges toward 5 m |

Apple also exposes a per-pixel confidence map for scene depth; this app currently exports the depth values themselves and does not filter by confidence. Treat the TIFF as a dense distance field for the framed view, not as a survey instrument.

### Upright / accelerometer (Core Motion)

The level uses **device motion gravity** (fused IMU estimate via Core Motion), not raw accelerometer samples alone. Gravity is low-pass filtered, then tilt from vertical is computed with `atan2` so small angles stay readable.

| Aspect | Behavior in this app |
| --- | --- |
| Display | Tilt shown to **0.01°** when not level |
| “Level” (green) | Only when total tilt, roll, and pitch are within **0.05°** of plumb, and that state holds for **0.25 s** (rejects brief noise) |
| Practical limit | After filtering, **~0.05°** is a realistic noise floor for a stable green reading on a still phone |
| Purpose | Help you hold the device **square / upright** so depth samples are taken with a consistent camera attitude |

That angular threshold is much tighter than casual bubble levels; it is meant for careful, stationary setup. Hand tremor, walking, or resting the phone on a soft surface will keep it orange.

## How to run

1. Open `lidar.xcodeproj` in Xcode.
2. Select a LiDAR-capable physical device.
3. Build & Run and allow camera access.
4. Set Near / Far for the scene, wait for the level to go green if you need a plumb capture, then tap the shutter.

## Main pieces

- `LiDARDistanceSession.swift` — ARKit session, scene depth, capture
- `DepthTIFFExporter.swift` — Float32 meters TIFF export
- `DepthRangeOverlayRenderer.swift` — live in-range false-color overlay
- `UprightLevelMonitor.swift` — Core Motion plumb / level indicator
- `ContentView.swift` — UI

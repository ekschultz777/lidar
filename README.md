# lidar

An iOS app that captures **LiDAR scene depth** from a LiDAR-equipped iPhone or iPad and exports it as a quantitative depth image, with a live **plumb / upright level** so you can hold the phone square when measuring.

Requires a device with a LiDAR scanner (for example iPhone 16 Pro). Built with ARKit `sceneDepth` and Core Motion.

## What it does

- Live camera preview with a false-color overlay of depths from **0–1 m**.
- **Capture** (shutter button or remote HTTP) saves:
  - a photo to the Photos library (camera roll)
  - a **Float32 TIFF** where each pixel is distance from the camera plane in **meters** (values outside 0–1 m, and invalid samples, are `0`)
- While the app is open, a Bonjour HTTP server on port **8080** lets a Mac on the same Wi‑Fi trigger a capture and download a ZIP of the JPEG + TIFF.
- A **level bubble** in the corner shows how close the phone is to perfectly upright (portrait, plumb). It turns green only when tilt is essentially zero.

## Measurement accuracy

### LiDAR depth

Depth comes from ARKit’s LiDAR-backed scene depth map (`ARFrame.sceneDepth`), not from a separate ranging algorithm in this app. Each TIFF sample is stored as a 32-bit float in meters, so the **file can represent millimeter-scale values**, but that is storage precision—not a guarantee that every sample is that accurate in the real world.

In practice, for Pro / Pro Max class devices:

| Aspect | Expectation |
| --- | --- |
| Useful range | Hardware is often usable to ~5 m; this app keeps **0–1 m** |
| Typical accuracy | Often **~1 cm or better** at close / mid range on matte surfaces; independent tests of iPhone LiDAR often report on the order of **~5 mm RMSE** in favorable conditions |
| Best results | Steady hold, diffuse surfaces, good lighting for the fused RGB+depth map, subjects inside 1 m |
| Weaker results | Very reflective, transparent, or light-absorbing surfaces; edges and thin structures |

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
3. Build & Run and allow camera, Photos, and **Local Network** access.
4. Wait for the level to go green if you need a plumb capture, then tap the shutter (or use remote capture below).
5. Keep the app in the foreground while using remote capture. The bottom of the UI shows a ready-to-copy `curl` example.

## Remote capture (Bonjour + curl)

The phone advertises an `_http._tcp` Bonjour service named after the device (Settings → General → About → **Name**). Hostname for curl is that name with spaces turned into hyphens, plus `.local`, on port **8080**.

### Helper script (recommended)

From a Mac on the same Wi‑Fi, with the lidar app open:

```bash
./scripts/find-lidar-phone.sh
```

It browses Bonjour, checks `/health` so only real lidar phones are offered, lets you pick one if there are several, then prints ready-to-run `curl` commands.

### Find the phone manually

Browse for the service:

```bash
dns-sd -B _http._tcp local.
```

Leave it running until you see an entry whose instance name matches your iPhone. Then resolve hostname and port (use the exact name from the browse output; quote it if it has spaces):

```bash
dns-sd -L "Your iPhone Name" _http._tcp local.
```

You can also read the name on the phone and form `Your-iPhone-Name.local` yourself (spaces → `-`).

### Capture and download

With the lidar app open and tracking:

```bash
curl http://Your-iPhone-Name.local:8080/capture -o capture.zip
```

That triggers a capture on the phone (also saved to the camera roll) and downloads a ZIP containing a timestamped `.jpg` and `.tiff`.

Health check:

```bash
curl http://Your-iPhone-Name.local:8080/health
```

## Main pieces

- `LiDARDistanceSession.swift` — ARKit session, scene depth, capture
- `CaptureHTTPServer.swift` — Bonjour HTTP server (`GET /capture` → ZIP)
- `DepthTIFFExporter.swift` — Float32 meters TIFF export
- `DepthRangeOverlayRenderer.swift` — live in-range false-color overlay
- `UprightLevelMonitor.swift` — Core Motion plumb / level indicator
- `ContentView.swift` — UI

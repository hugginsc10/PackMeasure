# PackMeasure

PackMeasure is a native iPhone LiDAR app for estimating the rectangular
packing size of boxes, furniture, and other moving items. Each saved scan adds
to a cargo-floor estimate, cubic volume, and a conservative van or moving-truck
recommendation.

## Project status

PackMeasure is an early open-source alpha. The end-to-end scan, local inventory,
packing totals, and vehicle-planning flows work on a LiDAR-equipped iPhone, but
real-device dimensional calibration is still in progress. A recent known-box
check measured a stated 24 × 20 × 20-inch box as 24 × 24 × 20 inches. Do not use
the current estimates as the sole basis for tight clearances or safety-critical
loading decisions.

## Use it

1. Put one item in view with visible separation from the background.
2. Stand at a three-quarter angle so the front, side, and top are visible.
3. Keep the center reticle on the item and tap **Start measurement**.
4. Hold still for the one-second depth capture.
5. Review the estimated length, width, height, and point-cloud quality.
6. Set quantity, stacking, and whether the item may safely turn on its side,
   then save it.

Retake low-confidence scans. Clear, matte boxes with visible edges produce the
best first-pass measurements. Glass, mirrors, shiny metal, thin objects, heavy
occlusion, and items touching a similarly deep background can be harder for
LiDAR to isolate.

## Understand the plan

- **Cargo floor** is the stack-adjusted footprint plus a 10% packing allowance.
- **Cargo volume** is the measured rectangular volume plus the same allowance.
- **Load mix** applies a realistic usable-volume fraction for boxes, mixed
  household goods, or bulky furniture.
- A vehicle is recommended only when every item clears its estimated interior
  and rear door with a two-inch fit buffer.

Rental fleets vary. Verify the assigned vehicle's interior and rear-door
measurements before booking or loading.

## Install on an iPhone

1. Open `PackMeasure.xcodeproj` in Xcode 27.
2. Select the **PackMeasure** target, then **Signing & Capabilities**.
3. Leave **Automatically manage signing** enabled, choose your Personal Team,
   and replace the example bundle identifiers if Xcode reports a conflict.
4. Connect and unlock the iPhone, select it as the run destination, and press
   **Run**.
5. Approve trust or Developer Mode if iOS requests it, then allow camera access
   on first launch.

The app requires an iPhone or iPad with LiDAR scene-depth support. Inventory is
stored locally in the app's Application Support directory; the app has no
network service.

## Verify the project

```sh
xcodegen generate
xcodebuild test \
  -project PackMeasure.xcodeproj \
  -scheme PackMeasure \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

Simulator tests validate segmentation, geometry, persistence, and packing
math, but the simulator cannot validate LiDAR accuracy. Use
`Docs/DeviceCalibration.md` for the real-device check.

## Contributing

Bug reports, calibration fixtures, device results, and focused pull requests
are welcome. Please include tests for geometry, scanner-state, or packing-logic
changes and clearly distinguish simulator evidence from physical LiDAR results.

## License

PackMeasure is available under the [MIT License](LICENSE).

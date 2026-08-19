# Real-device calibration

Use a tape measure and three rectangular objects with clearly different sizes.
Run each scan from a three-quarter angle with the center reticle on the object.

| Object | Actual L × W × H | Scan 1 | Scan 2 | Best absolute error | Confidence |
|---|---|---|---|---|---|
| Small box |  |  |  |  |  |
| Medium box |  |  |  |  |  |
| Large box or tote |  |  |  |  |  |

For each dimension:

```text
absolute error = |measured - actual|
percent error = absolute error / actual × 100
```

## Physical-device acceptance check

- Camera permission appears once and the live preview opens.
- Each known box returns all three dimensions after a one-second capture.
- Two scans of the same setup are reasonably repeatable.
- A poor angle or weak point cloud is labeled low-confidence or asks for a
  retake instead of silently saving a false measurement.
- Saving, force-quitting, and reopening preserves the inventory.
- Quantity and stack controls change floor square feet.
- The recommendation rules out a vehicle when an item cannot clear its door.

Treat a box result within roughly 5% per dimension as a strong MVP result.
Larger error, repeated underestimation, or unstable results means the depth
segmentation thresholds need tuning before relying on the estimate for a tight
vehicle fit.

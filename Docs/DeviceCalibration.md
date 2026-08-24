# Real-device calibration

Use a tape measure and three rectangular objects with clearly different sizes.
Keep each object stationary while capturing the requested independent angles.

| Object | Actual L × W × H | Angle 1 | Angle 2 | Angle 3 | Final estimate | Best absolute error | Confidence |
|---|---|---|---|---|---|---|---|
| Small box |  |  |  |  |  |  |  |
| Medium box |  |  |  |  |  |  |  |
| Large box or tote |  |  |  |  |  |  |  |

For each dimension:

```text
absolute error = |measured - actual|
percent error = absolute error / actual × 100
```

## Physical-device acceptance check

- Camera permission appears once and the live preview opens.
- Each known box returns all three dimensions after the multi-angle workflow.
- A same-position second photo is rejected as too similar.
- Two captures never resolve by themselves, even when their dimensions agree.
- The third capture must come from a distinct side and change camera height by
  roughly 8 inches (20 cm); a flat third view is rejected without clearing the
  first two angles.
- A materially larger discordant third result blocks saving instead of being
  silently discarded.
- The accepted result keeps all contributing angle measurements visible.
- Missing LiDAR support near an isolated silhouette endpoint asks for a retake
  instead of accepting a shortened dimension.
- A poor angle or weak point cloud is labeled low-confidence or asks for a
  retake instead of silently saving a false measurement.
- Saving, force-quitting, and reopening preserves the inventory.
- Quantity and stack controls change floor square feet.
- The recommendation rules out a vehicle when an item cannot clear its door.

Treat a box result within roughly 5% per dimension as a strong MVP result.
Larger error, repeated underestimation, or unstable results means the depth
segmentation thresholds need tuning before relying on the estimate for a tight
vehicle fit.

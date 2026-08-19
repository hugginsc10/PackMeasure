# PackMeasure native MVP

## Outcome

PackMeasure turns one iPhone capture action into a conservative packing
bounding box for a centered object, saves the item, and recommends the
smallest vehicle profile that can carry the accumulated inventory.

The capture may sample several LiDAR frames during a short hold. The user does
not place a reference object, calibrate a scale, or tap measurement endpoints.

## Primary journey

1. Frame a box or object at a three-quarter angle so its front, side, and top
   are visible.
2. Tap **Start measurement** and keep the object inside the reticle for roughly one
   second.
3. Review the estimated length, width, and height, plus a point-cloud quality
   indicator that does not claim dimensional accuracy.
4. Name the item, adjust quantity and stackability, then save it.
5. Review total floor footprint, cubic volume, largest-item constraints, and
   the smallest planning vehicle that fits.

## Measurement contract

- Dimensions describe the smallest conservative rectangular packing box, not
  the contours or usable internal volume of the object.
- LiDAR estimates are approximate. Low-confidence or incomplete scans must be
  labeled and offer a retake rather than silently reporting false precision.
- A single capture action may include a short multi-frame depth sweep; it is
  not a monocular AI guess from RGB pixels.
- Real-device calibration against known boxes is part of the definition of
  done. Simulator builds alone cannot verify LiDAR behavior.

## Vehicle contract

- Recommendation must satisfy adjusted capacity and largest-item clearance.
- Floor square feet and cubic feet are both reported because neither alone is
  sufficient.
- Vehicle profiles are planning estimates and must expose their assumed cargo
  dimensions and usable-volume factor.

## MVP acceptance criteria

- App builds for iOS 27 and launches on a LiDAR-capable iPhone.
- Camera permission and LiDAR support checks are handled.
- A known rectangular box can be scanned, reviewed, and saved.
- Inventory survives relaunch.
- Totals and a vehicle recommendation update after adding/removing items.
- Geometry and packing math unit tests pass.
- Known-box device checks record error on all three dimensions; results and
  project documentation are labeled honestly if the desired tolerance is not
  yet met.

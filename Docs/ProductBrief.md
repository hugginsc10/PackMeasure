# PackMeasure native MVP

## Outcome

PackMeasure compares independent iPhone capture angles to estimate a packing
bounding box for a centered object, saves the item, and recommends the smallest
vehicle profile that can carry the accumulated inventory.

After a short settling interval, the capture processes one synchronized camera
and LiDAR depth frame. The user does not place a reference object, calibrate a
scale, or tap measurement endpoints.

## Primary journey

1. Frame a box or object at a three-quarter angle so its front, side, and top
   are visible.
2. Tap **Take photo** and hold still briefly while the app processes the capture.
3. Keep the item still, move around it, and capture a second verified viewpoint.
   If raw dimensions disagree, capture one final distinct angle.
4. Review the estimated long side, short side, and height plus the number of
   agreeing angles. Agreement is presented as repeatability evidence, not an
   accuracy claim.
5. Name the item, adjust quantity and stackability, then save it.
6. Review total floor footprint, cubic volume, largest-item constraints, and
   the smallest planning vehicle that fits.

## Measurement contract

- Dimensions describe the smallest conservative rectangular packing box, not
  the contours or usable internal volume of the object.
- LiDAR estimates are approximate. Low-confidence or incomplete scans must be
  labeled and offer a retake rather than silently reporting false precision.
- Save remains disabled until at least two independent viewpoints agree on all
  three raw dimensions. The second camera position must be at least 15 cm away
  horizontally and 25 degrees around the stationary object.
- Pair agreement currently requires every raw axis to differ by no more than
  1.5 inches and 15%, with no more than a 20% rectangular-volume spread. These
  are provisional repeatability gates and require calibration on more objects.
- When two photos disagree, a third distinct angle adjudicates them. A larger
  discordant result is never silently thrown away; unresolved series must
  restart.
- High confidence requires independent-view agreement plus High point-cloud
  evidence from every contributing photo, not merely multiple depth frames
  from the same pose.
- A single capture action uses one synchronized camera-and-depth frame after a
  short settling interval; it is not a monocular AI guess from RGB pixels.
- The camera mask is the preferred object boundary. If it contains no
  foreground instance, the same frame may use the center-reticle LiDAR region
  as a shape-agnostic fallback while retaining floor and background rejection.
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

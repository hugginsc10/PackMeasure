# Drawer and cabinet scanning — Build 59

## Automatic compartment sweep

The default workflow is **Choose → Sweep → Review**. Tap a visible patch on the
inside base of one drawer or shelf compartment (or use **Scan base at cross**).
Move the phone slowly to show the base, sides and front. Teal patches show observed
floor coverage. Keep the compartment stationary. The app calculates corners;
individual corner placement is no longer the default capture workflow.

**Review dimensions** appears after consecutive reconstructions agree across
distinct views and a sufficiently covered underside provides clear height. If
only the footprint is ready, **Use outline · set height** retains it and offers
the existing height capture/entry. The user still reviews and saves explicitly.
Automatic height estimates the observed overhead clearance; verify drawer closure,
hinges, lips, taper and overhangs before manufacturing an insert.

**Choose another base** clears this target without restarting the AR session.
Manual correction and the older single-view detector remain in **Scan options**.
Switching to manual correction retains a stable completed sweep outline, including
its notches and obstacle loops. An incomplete sweep cannot invent a perimeter.

### Reconstruction and evidence

`InteriorSweepFrame` copies scene depth, confidence, depth-aligned luminance,
calibration and pose from one fresh, normally tracked frame. A base selection fits
a local level patch within two depth pixels of the tap. This is explicit target
selection, not the exact-pixel measurement path used by manual corners; no remote
surface or image-center fallback is used.

`InteriorSweepWorker` processes immutable snapshots off the main actor, admitting
at most one reconstruction at a time. Useful camera movement produces keyframes
(approximately 18 mm translation or 3 degrees rotation); stationary repeats do not
establish independent support. Collection is bounded to 40 keyframes within 1.2 m
of the selected base. At that limit novel usable evidence can replace a redundant
view, preserving coverage and corroboration of late edges and lower obstructions.

The worker accumulates observed base patches, near-base vertical surface samples,
and open-front edge samples. An open front needs observed depth beyond the base
or a supported vertical trim face just below it, plus nearby base evidence and an
image intensity change. Missing depth or an image edge alone
does not close the outline. High-confidence measurements remain required.

An 8 mm spatial grid identifies the connected target footprint and orders its
boundaries. Supported lines are robustly fitted to the boundary samples and their
intersections provide the final corner positions. The grid does not determine the
reported dimensions. Disconnected neighboring floors are excluded. Concave
boundaries and supported holes are preserved by the default **Follow edges**
model. **Rectangle** is an explicit choice before selecting the base, for four
straight sides at right angles; it requires four supported sides first.
Unsupported borders, significant unknown interior patches, crossing
geometry and inconsistent reconstruction prevent review.

Overhead capture requires horizontal patches observed from below in at least two
views, agreement between per-view heights, and broad spatial coverage of the
footprint. It does not use a shelf's top face as its underside. Incomplete or
inconsistent coverage leaves height for the user to capture or enter.

Temporary non-normal tracking pauses acceptance. Interruption, relocalization,
backgrounding or an actual session reset invalidates unfinished world coordinates.
Generation checks prevent late worker output from entering a different scan.
Completed review results remain intact. **Scan diagnostics** exports a bounded,
replayable set of geometry keyframes and the latest interruption reason only when
the user chooses to share; camera photographs are not included or saved.

#### 2026-10-02 — Surfaces just inside a side (issue #33)

A hinge plate a few millimetres inside a side fits as a short line parallel to it.
Where the traced border offers both, matching now prefers the parallel line lying
deeper into the base, and when two such sides collapse, the kept line's extent is
widened to cover the dropped one so the corners at either end stay supported. The
outline narrows to the plate rather than stalling on an unsupported corner.

Line fitting itself now tells such a plate apart from a side's own scatter. A separate
band of samples 5–14 mm inside a fitted wall gets a line of its own when it has a
line's support (two views, at least 3.5 cm long), is as dense as the wall's samples and
stands out from the thinner scatter on either side of it; a single noisy side still fits
as one edge at its mean, and the open front and the device fixture are unchanged. A strip
that replaces the side over part of its length, which the band fits as one tilted blend, is
now split from the side when the two levels are 5–14 mm apart and clearly separated
relative to their scatter; a straight or gently bowed wall is never split. A strip under
about 5 mm, or one seen with heavy scatter, is still left at the blended offset, which
errs a few millimetres wide.

#### 2026-10-03 — Accuracy investigation and retained-state replay

Two Build 61 captures of the same rectangular compartment reproduce 10.57 × 10.61
and 11.05 × 10.71 inches along/across the first edge. Tape measurements confirm
both widths are 10.5 inches and both depths are 11.2 inches; the first edge is the
depth direction in these captures. These are error regression fixtures, not
physical acceptance results. Broader coverage improves depth but does not remove
the spurious taper or width error.

Similar consecutive reconstructions establish output stability, not agreement
between the views used to fit them. Each resolved edge now records the 10th–90th
percentile span of per-view median normal residuals within the 15 mm surface band,
excluding 20 mm at the corners. A view needs six samples spanning 35 mm; a spread
needs three views. Views get equal weight irrespective of sample density. The
largest recorded spread is shown as **Captured boundary variation** in review
and survives save/reopen. It is not an absolute error bound: shared bias, samples
outside the band, sparse/unobserved edges and weak viewpoint diversity remain
unmeasured. It does not change the ready gate, dimensions or insert clearance.

Diagnostics v2 retains bounded 3D wall samples (8 mm voxels, up to 8,000 per view)
before height is discarded for the existing planar fit. This preserves evidence
used by the rectangular model to fit wall planes on a new device scan; legacy
v1 captures cannot recover it. Plane inclination alone cannot distinguish a real
leaning wall from capture/projection bias. V2 also exports acceptance
counters, the worker reconstruction, the selected scan result, and available
review height/source as separate fields. The review measurement is the scanner's
draft, before any edits made locally in the review form.

`InteriorSweep(snapshot:)` restores retained observations directly, with bounds
and finite-value validation, rebuilding evidence cells for subsequent use. Do
not feed a retained snapshot through `add` as if it were the original acquisition
stream: the 40-view fixture has already undergone replacement, and readmission
rejects a view that was admitted with the original, now-discarded history. V1 is
supported; its missing total acceptance counter falls back to retained count.

The default line fitter and outline readiness are unchanged. The optional
**Rectangle** model adds a fit after the original supported corners resolve. It
rejects outer outlines with other than four corners or directions more than
0.12 radians from common orthogonal axes. Wall views vote on a shared orientation;
each qualifying view contributes one median offset, so a dense view cannot
outvote several agreeing views. The open front retains its supported location,
including the existing observed-floor snap; it is not extended to a tape value.
Nearer hinge/trim constraints and obstacle loops are preserved. Adjusted corners
must remain within 40 mm of their supported originals; final geometry validation
and the existing 97 percent floor coverage gate still apply.

When 3D evidence is available, a wall view fits normal distance against position
along the edge and height above the selected base, using three Huber-weighted
passes. It needs 12 samples, at least 75 mm along the edge and 35 mm vertically,
and a well-conditioned covariance. Along-edge/height slopes are limited to
0.12/0.2 and the base intercept to 25 mm from the initial wall. The fitted plane's
intersection with the selected level base supplies that view's offset. Thin or
diagonal patches fall back to 2D evidence. The diagnostics record how many views
used a plane for each edge; v1 fixtures correctly report zero.

This estimates a **base footprint**, not the usable cavity at every height.
Real inward-leaning walls or overhangs can require a smaller insert above the
base. Check all four sides and clearance at the intended insert height.
The chosen model is retained in diagnostics and saved measurements. Review labels
rectangular captures explicitly; Follow edges remains the default for irregular
compartments.

Both legacy captures become straight rectangles in the native Swift replay.
Width error drops to about 0.34/0.44 mm and worst actual-edge error improves from
19.99/9.11 mm to 19.26/6.42 mm. The wide capture's bounding depth becomes shorter
than its original bounding span even while its worst actual-edge error improves;
bounding spans alone are not the accuracy criterion. These are two regression
fixtures with a user-confirmed rectangular prior, not independent dimensional
acceptance. No tape dimensions enter the production fit. A fresh v2 device scan
is still required to validate the 3D path. Every edge, obstacle and height needs
physical validation.

### Physical acceptance

Synthetic tests cover partial views, open fronts, rotated/noisy geometry, notches,
obstacles, missing boundaries, adjacent compartments, height coverage and session
invalidation. They do not prove real-device accuracy or successful detection of
every material, narrow detail or occluded edge. The first physical check is one
empty drawer and the previously photographed cabinet compartment, with no corner
taps: select the base, sweep, review, and compare width/depth/height with a ruler.
Record any repeated prompt and share scan diagnostics if the outline stays
incomplete. Small details and hidden obstructions still require inspection.

## Retained manual workflow

The interior workflow captures a level footprint with optional obstacle cutouts
and one usable height for a fitted insert. Build 58 prioritizes obtaining an
outline and placing/correcting corners without repeatedly aiming a live reticle.
It preserves concavity, millimeter editing, clearance and 1:1 SVG export.

## Flow

Home → **Measure a drawer or cabinet → Scan drawer or cabinet** opens three stages:
Outline, Height and Review. Empty and secure the compartment before capture.

- **Find outline** starts the existing seeded LiDAR floor detector. It still
  requires observed raised boundaries, fresh depth and three consistent previews.
  **Use this outline** pins the result and moves directly to height. **Edit outline**
  returns to corrections without discarding it. **Retry from cross** picks a new
  floor seed when detection struggles. After seeding, previews no longer depend
  on obtaining a separate reliable reading at the current center cross.
- **Place corners myself** offers **Freeze & zoom**. Freeze a visible section,
  pinch/pan, and tap the inside floor corners in perimeter order. Each tap places
  one point. Numbered dots and connecting lines identify the captured points.
  **Resume camera** retains them, allowing another angle and another frozen view
  in the same uninterrupted AR session. This is manual point accumulation, not
  automatic fusion of partial boundaries or hidden-corner inference.
- Choose a numbered corner and tap its corrected location, or move it with the
  live cross. A valid correction updates only that corner. **Undo** removes the
  most recently added point or cancels the selected correction. **Add obstacle**
  preserves the outer outline, including one produced automatically. Trace each
  cutout around its base, then continue to height. **Start over** explicitly clears
  the unfinished scan after confirmation.
- Capture or tap a visible top edge above the footprint. It no longer has to be
  directly above the orange first corner. The top point must lie above the outer
  footprint or within 30 mm of its boundary and outside obstacle interiors.
  Choose the lowest usable height, accounting for drawer closure and obstructions.
  Alternatively, **Enter measured height** accepts inches or millimeters. Guided
  heights are 10–3,000 mm. Entered heights retain a distinct source; editing a
  captured height in review changes it to entered. Old saved records still decode.
- Review the footprint and height, adjust clearance, use the always-visible **Save**
  button, and optionally export
  an SVG. Side clearance applies at every wall and obstacle. This remains a 2D
  footprint plus height, not a complete tapered/overhung 3D cavity.

## Capture and lifecycle

`InteriorPhoto` retains the full camera image, depth/confidence grid, intrinsics,
image resolution and camera pose from the same fresh, normally tracked AR frame.
The raw image is rotated clockwise for portrait. Taps in the zoomable image map
back to normalized original-image coordinates, then sensor coordinates. The
existing exact-pixel depth sampler unprojects that pixel using the frozen frame's
calibration and pose. Low-confidence, missing and out-of-range depth fail at that
point; no nearby pixel, image center or inferred plane is substituted. A point
must still pass level-floor and outline geometry checks.

Photo overlays project the existing world points back through that same pose and
intrinsics. Zoom changes display only. Unknown/behind-camera points break overlay
lines instead of creating spurious connections. Images/depth snapshots are
transient and are not saved to the interior store. New photographs and the live
reticle share a coordinate system only while the tracking session remains intact.

Backgrounding, AR interruption, relocalization and explicit reset invalidate
unfinished photos and points. Old-generation snapshots cannot place points in a
new scan. Completed review results survive. Ordinary help/height sheets no longer
clear geometry just because the scene briefly becomes inactive. Interior markers
now have an owned SceneKit node; refreshing them does not remove ARSCNView's
camera node.

The shared photo picker also serves the Build 57 wire-shelf flow. Outline overlays
are optional, so wire matching keeps its existing single crosshair behavior.

## Verification and limits

New tests cover photo/world round-trip mapping, exact-pixel confidence rejection,
viewpoint continuation, stale snapshots, pinned-outline obstacle insertion,
single-corner correction, direct transition to height, stale preview rejection,
height footprint containment, entered-height boundaries and legacy persistence.
UI fixtures exercise frozen placement/correction/save/reopen, obstacle addition,
automatic-outline navigation and depth rejection after zoom. Wire flow UI checks
are repeated because the photo picker is shared.

These are software and synthetic-image checks. Real-device corner registration,
LiDAR dimensions, repeatability and insert fit remain to be tested. Automatic
outline detection still needs the whole floor boundary in one view; a cabinet
lip/roof or missing depth may require manual placement from several viewpoints.

Minimal physical check: freeze one drawer view, zoom and tap its corners, then
resume and move the phone. Confirm the markers stay on the actual corners. Try
one correction and an obstacle, enter or capture height, and save/reopen. Compare
with a ruler/caliper. For a cabinet, keep the compartment still and continue from
a second angle. If tracking resets, start a fresh scan. Print a thin test outline
before a full fitted insert.

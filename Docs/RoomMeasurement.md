# LiDAR room measurements

Choose **Measure a room** on the home screen, then **Scan a room**. On a supported
LiDAR iPhone, allow the camera and follow RoomPlan's coaching. Walk slowly around
one room, including every corner, doorway, and floor-to-wall edge. Tap **Finish**,
review the outline and wall dimensions, name the room, and tap **Save**.
Saved rooms are separate from the moving inventory. Share measurements from the
saved room detail. All storage is local; no scan is uploaded by the app.

The overview reports spans aligned with the longest captured wall and the maximum
captured wall height. It is an approximate bounding extent, not floor area,
ceiling clearance, or proof of a complete room. Each wall also has its own length,
height, and RoomPlan confidence. An L-shaped room preserves its separate walls.
Missing walls can understate the extent. Low confidence walls remain visible.

## Physical acceptance (pending)

1. Rectangular room: independently measure two perpendicular walls and wall height.
   Scan three times, starting in different corners; record each wall, overall spans,
   confidence, absolute error, and repeatability in meters and feet.
2. Furnished room: repeat with a chair, sofa, and cabinet against walls. Check that
   furniture does not become a wall or truncate the measured room.
3. L-shaped room: check every segment against tape. The overview must remain an
   extent; it must not claim the bounding rectangle is usable floor area.
4. Partial scan: deliberately omit a wall. Verify the outline exposes the gap and
   the approximate-extent explanation stays visible.
5. Lifecycle: deny permission, close mid-scan, background mid-scan, reopen, finish
   immediately, finish normally, then save and relaunch. No frozen camera or
   duplicate result. Verify room scans do not change the item inventory.
6. Share a saved result and verify units, name, wall numbering, and confidence.

Simulator geometry/persistence tests do not validate Apple's capture callbacks,
LiDAR accuracy, completeness, or real-world usability. Report measured errors
before setting a product accuracy claim or releasing this as calibrated.

Reference: https://developer.apple.com/documentation/roomplan

## Partial-scan recovery (Build 44)

Build 43 rejected all measurements if fewer than three walls were returned, any
wall was invalid, or the footprint was degenerate. Build 44 preserves every
valid wall and reports the count of excluded invalid walls. Partial scans can be
saved, but do not show an overall room span. All-invalid/empty results still fail
with the detected count, a new-scan button, and user-initiated diagnostic sharing.

The capture view shows a live detected-wall count. Results offer Scan again and
Diagnostics; diagnostics include the build, duration, live/final wall counts,
raw wall dimensions, and error, but no photos or point clouds. Share before
retrying or closing, because diagnostics are session-local.

Retest: intentionally finish after two highlighted walls, verify a partial
result with two wall measurements and no overall span, then scan again and
capture the rest of the room. Save/reopen both partial and fuller results.
Screenshots IMG_5573/5574 and the user's live-wall-highlights report establish
that Build 43's post-processing validation failed, but do not identify which
validation condition fired or prove a particular RoomPlan fault.

## Interactive floorplan

Open a saved room (or a new scan result) and tap **Explore floorplan**. Pinch to
zoom up to 8x and drag to pan. Double-tap to zoom in; double-tap beyond 3x to
return to the overview. **Fit** restores the whole outline.

Tap a wall or its number to highlight it and read its saved length, height,
and capture confidence. The wall menu and previous/next buttons also provide
access to every segment. Badges remain readable as you zoom; overlapping badges
are hidden until space is available, with the selected wall taking priority.
Low-confidence walls are orange, and the selected wall is teal. **Done** returns
to the saved result. Viewing does not modify the scan or its measurements.

Viewer validation: select walls at fit and zoomed scale, pan and select again,
restore Fit, choose a crowded segment from the menu, and reopen the saved room.
Repeat on a one-wall partial scan. Capture accuracy remains a separate check.

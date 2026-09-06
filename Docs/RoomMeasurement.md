# LiDAR room measurements

Choose **Measure a room** on the home screen, then **Scan a room**. On a supported
LiDAR iPhone, allow the camera and follow RoomPlan's coaching. Walk slowly around
one room, including every corner, doorway, and floor-to-wall edge. Tap **Finish**,
review the numbered outline and wall dimensions, name the room, and tap **Save**.
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

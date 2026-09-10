# General-object capture validation

Choose **General Item** before selecting the target for luggage, chairs, bins,
and furniture. **Box** uses a rigid-body profile check that is inappropriate for
some connected, irregular shapes. General Item keeps ownership, photo-edge,
LiDAR endpoint support, and cross-angle checks enabled.

After a capture attempt, **Share scan diagnostics** in the scanner toolbar exports
up to 12 recent frame extraction reports from this scanner session. It includes
build, subject mode, request/series IDs, rejection code/details, sample count,
region coverage, multiplicity route, and estimated dimensions. It contains no
camera image or point cloud. The share sheet lets the user choose a destination;
the app does not transmit automatically. Reports are session-local, so share
before closing the scanner. A successful frame report is not proof that the
multi-angle ownership/consensus checks accepted it or that its dimensions are accurate.

## Repeatable physical test card

Measure the object's enclosing length, width, and height with tape first. Include
handles, legs, wheels, and protrusions in the configuration being scanned. Keep
the object stationary and use three distinct viewpoints, including the requested
height change. Repeat each object three times.

| Object | Mode | Details to check |
| --- | --- | --- |
| Matte box (control) | Box | First capture, three angles, touching-neighbor rejection |
| Suitcase | General Item | Wheels and handle included; record handle position |
| Rounded bin | General Item | Rim and base remain in outline |
| Chair | General Item | Back, seat, legs; background through gaps excluded |
| Side table | General Item | Top and legs included as one object |
| Sofa or armchair | General Item | Arms/cushions included; enough room to frame whole item |
| Tall lamp | General Item | Base, thin stem, shade; explicit rejection is a result to record |

For each attempt record: build, object, mode, tape L/W/H, scan L/W/H, accepted
angles, retries, failure code, and the exported diagnostic text. Capture the
outline screenshot when it excludes part of the object or includes a neighbor.
Test both isolated placement and ordinary clutter, without moving the target
between angles. Also retest the Build 42 failure scenes.

The added production-policy fixtures cover a rounded bin, suitcase with handle
opening, chair with separated legs, and L-shaped furniture. They use synthetic
silhouettes and dense planar depth to verify point-cloud admission and retention,
not Vision recognition, full 3D dimensions, or real LiDAR accuracy. A clipped
object remains rejected. Existing physical failures are not declared fixed by
these fixtures; their next diagnostic reports are needed to isolate the cause.

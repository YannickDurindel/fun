extends RefCounted
## Hand-made trackside table of the Baku City Circuit, loaded by track id by TracksideLayout
## (scripts/track/trackside_layout.gd). See red_bull_ring.gd for the format.
##
## A street circuit: the automatic layout would give it gravel traps, tarmac run-off and
## barriers 10 to 30 m from the road. Here the walls stand 2.5 m from the road edge all round
## (the closest the barrier code allows is 2 m), there is no run-off at all, and every wall is
## concrete with a debris fence. The real circuit has escape roads straight on at Turns 1, 2, 3,
## 7, 15 and 16; they are not built, the wall just follows the corner.
##
## Between Turn 6 and Turn 7 the lap runs beside the main straight, on the other carriageway of
## Neftchilar Avenue. The barrier code puts both walls on the line half way between the two
## roads (TrackGeometry.proximity_limits), 0.25 to 1.3 m from the road edges: one wall between
## the carriageways, as in reality.
##
## Sides: "in" = inside of the corner, "out" = outside. Offsets are metres along the lap from
## the apex (negative = before the apex).

## [turn id, side, from, to, kind]   kind: flat | saw | sausage
## Flat kerbs on the inside of the right-angle street corners and the chicane. None in the
## castle section (Turns 8 to 12), where the walls are the kerbs, and none on the flat-out
## bends of the run to the line (Turns 17 to 20).
const KERBS: Array = [
	["T1", "in", -14.0, 14.0, "flat"],
	["T2", "in", -14.0, 14.0, "flat"],
	["T3", "in", -14.0, 14.0, "flat"],
	["T4", "in", -14.0, 14.0, "flat"],
	["T5", "in", -12.0, 12.0, "flat"],
	["T6", "in", -12.0, 12.0, "flat"],
	["T7", "in", -12.0, 12.0, "flat"],
	["T15", "in", -14.0, 14.0, "flat"],
	["T16", "in", -14.0, 14.0, "flat"],
]

## No gravel and no tarmac run-off anywhere.
const RUNOFF: Array = []

## Barrier distance from the road edge (m) before clamping to the local geometry.
const BARRIER_STRAIGHT: float = 2.5
## On the outside of a corner, from 60 m before the apex to 80 m after it.
const BARRIER_CORNER_OUTSIDE: float = 3.5
const BARRIER_BEHIND_RUNOFF: float = 2.5

## Concrete wall + debris fence for the whole lap: two ranges [from_s, to_s] that meet at the
## finish line and at s = 3000, so nothing depends on the exact lap length.
const CONCRETE_RANGES: Array = [[0.0, 3000.0], [3000.0, 0.0]]

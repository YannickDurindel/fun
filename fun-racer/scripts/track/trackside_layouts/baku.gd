extends RefCounted
## Hand-made trackside table of the Baku City Circuit, loaded by track id by TracksideLayout
## (scripts/track/trackside_layout.gd). See red_bull_ring.gd for the format.
##
## A street circuit: the automatic layout would give it gravel traps, tarmac run-off and
## barriers 10 to 30 m from the road. Here the walls stand 2 m from the road edge all round
## (the closest the barrier code allows; the real ones stand on the white line), and every
## wall is concrete with a debris fence. The real circuit has escape roads straight on at
## Turns 1, 2, 3, 7, 15 and 16. Three of them are open ground in the map and are built as
## tarmac run-off (Turn 1 into the continuation of Neftchilar Avenue, Turn 3 into Khagani
## Street, Turn 16 across Azneft Square, where the outside of the exit is painted asphalt:
## Wikimedia Commons, "Four Seasons Hotel Baku during 2019 Formula-1 Azerbaijan Grand
## Prix.jpg"); at the others buildings stand in the way and the wall just follows the corner.
##
## Between Turn 6 and Turn 7 the lap runs beside the main straight, on the other carriageway of
## Neftchilar Avenue. The recipe declares the two stretches a [[road.pair]], so the trackside
## builds one wall for both, on the middle of the 2.5 m median between them
## (Trackside._share_pair_walls): one wall between the carriageways, as in reality.
##
## Sides: "in" = inside of the corner, "out" = outside. Offsets are metres along the lap from
## the apex (negative = before the apex).

## [turn id, side, from, to, kind]   kind: flat | saw | sausage
## Red and white kerbs on the inside of the right-angle street corners and the chicane, and
## on the outside of the exits where the cars run wide (seen at Turn 16 in the photograph
## above, and at Turns 1, 2, 3 and 15 on the onboard laps). None in the castle section (Turns 8
## to 12), where the walls are the kerbs, and none on the flat-out bends of the run to the line
## (Turns 17 to 20). Lengths are estimates.
const KERBS: Array = [
	["T1", "in", -14.0, 14.0, "flat"],
	["T1", "out", 10.0, 45.0, "flat"],
	["T2", "in", -14.0, 14.0, "flat"],
	["T2", "out", 10.0, 45.0, "flat"],
	["T3", "in", -14.0, 14.0, "flat"],
	["T3", "out", 10.0, 45.0, "flat"],
	["T4", "in", -14.0, 14.0, "flat"],
	["T4", "out", 10.0, 40.0, "flat"],
	["T5", "in", -12.0, 12.0, "flat"],
	["T6", "in", -12.0, 12.0, "flat"],
	["T6", "out", 8.0, 40.0, "flat"],
	["T7", "in", -12.0, 12.0, "flat"],
	["T15", "in", -14.0, 14.0, "flat"],
	["T15", "out", 10.0, 45.0, "flat"],
	["T16", "in", -14.0, 14.0, "flat"],
	["T16", "out", 10.0, 60.0, "flat"],
]

## [turn id, side, from, to, kind, u_from, u_to]: the three escape areas that are open ground.
## Depths are estimates from the width of the streets they run into.
const RUNOFF: Array = [
	["T1", "out", -30.0, 20.0, "tarmac", 0.0, 9.0],
	["T3", "out", -40.0, 16.0, "tarmac", 0.0, 6.0],
	["T16", "out", 0.0, 95.0, "tarmac", 0.0, 6.0],
]

## Barrier distance from the road edge (m) before clamping to the local geometry.
const BARRIER_STRAIGHT: float = 2.0
## On the outside of a corner, from 60 m before the apex to 80 m after it.
const BARRIER_CORNER_OUTSIDE: float = 2.5
## Between the outer edge of a run-off and the wall behind it.
const BARRIER_BEHIND_RUNOFF: float = 1.0

## Concrete wall + debris fence for the whole lap: two ranges [from_s, to_s] that meet at the
## finish line and at s = 3000, so nothing depends on the exact lap length.
const CONCRETE_RANGES: Array = [[0.0, 3000.0], [3000.0, 0.0]]

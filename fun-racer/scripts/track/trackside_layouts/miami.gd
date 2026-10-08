extends RefCounted
## Hand-made trackside table of the Miami International Autodrome, loaded by track id by
## TracksideLayout (scripts/track/trackside_layout.gd); the format is that of red_bull_ring.gd.
##
## Why a table: the automatic layout puts the barriers 10 to 20 m from the road with gravel
## outside the corners, as on a permanent circuit. Miami is a temporary circuit laid out on the
## stadium's car parks: concrete blocks with debris fence stand along the road edge all round,
## and the only run-off is tarmac behind the three heavy braking zones (turns 1, 11 and 17).
## So here the wall stands 2.5 m from the road edge (the runtime's lower limit is 2 m), 4 m on
## the outside of the corners, with no gravel anywhere.
##
## The kerb positions and the run-off depths are estimates from the corner geometry, not
## surveyed. No sausage kerbs: with a flat kerb in front they would reach into the wall.
##
## Sides: "in" = inside of the corner, "out" = outside. Offsets are metres along the lap from
## the apex (negative = before the apex).

## [turn id, side, from, to, kind]   kind: flat | saw | sausage
const KERBS: Array = [
	["T1", "in", -22.0, 18.0, "saw"],
	["T1", "out", 5.0, 55.0, "saw"],
	["T2", "in", -20.0, 20.0, "saw"],
	["T3", "in", -18.0, 60.0, "saw"],
	["T4", "in", -30.0, 30.0, "saw"],
	["T4", "out", 15.0, 60.0, "flat"],
	["T5", "in", -30.0, 25.0, "saw"],
	["T6", "in", -25.0, 30.0, "saw"],
	["T6", "out", 20.0, 65.0, "flat"],
	["T7", "in", -40.0, 20.0, "saw"],
	["T7", "out", 5.0, 40.0, "saw"],
	["T8", "in", -25.0, 25.0, "flat"],
	["T9", "in", -25.0, 25.0, "flat"],
	["T10", "in", -30.0, 30.0, "flat"],
	["T11", "in", -22.0, 18.0, "saw"],
	["T11", "out", 5.0, 50.0, "saw"],
	["T12", "in", -35.0, 25.0, "saw"],
	["T12", "out", 15.0, 50.0, "saw"],
	["T13", "in", -25.0, 25.0, "saw"],
	["T13", "out", 15.0, 50.0, "saw"],
	["T14", "in", -14.0, 10.0, "saw"],
	["T15", "in", -10.0, 14.0, "saw"],
	["T16", "in", -18.0, 15.0, "saw"],
	["T16", "out", 5.0, 50.0, "saw"],
	["T17", "in", -22.0, 20.0, "saw"],
	["T17", "out", 5.0, 55.0, "saw"],
	["T18", "in", -30.0, 30.0, "saw"],
	["T18", "out", 20.0, 60.0, "flat"],
	["T19", "in", -30.0, 30.0, "flat"],
	["T19", "out", 20.0, 65.0, "flat"],
]

## [turn id, side, from, to, kind, u_from, u_to]   kind: tarmac | gravel
## u is metres outward measured from the outer edge of any kerb there (0 = right behind it).
const RUNOFF: Array = [
	["T1", "out", -80.0, 35.0, "tarmac", 0.0, 14.0],
	["T11", "out", -90.0, 30.0, "tarmac", 0.0, 16.0],
	["T17", "out", -100.0, 30.0, "tarmac", 0.0, 18.0],
]

## Barrier distance from the road edge (m) before clamping to the local geometry.
const BARRIER_STRAIGHT: float = 2.5
const BARRIER_CORNER_OUTSIDE: float = 4.0
## Space kept between the outer edge of a run-off area and the barrier line.
const BARRIER_BEHIND_RUNOFF: float = 2.0

## Concrete wall + debris fence: [from_s, to_s] absolute. The whole lap (5412 m).
const CONCRETE_RANGES: Array = [[0.0, 5411.99]]

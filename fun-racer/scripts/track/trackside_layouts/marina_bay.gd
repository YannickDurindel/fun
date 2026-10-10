extends RefCounted
## Trackside table of the Marina Bay Street Circuit, loaded by track id by TracksideLayout
## (scripts/track/trackside_layout.gd; format: see red_bull_ring.gd).
##
## A street circuit: concrete walls with debris fences right beside the road all the way
## round and no gravel. The automatic layout cannot do that (its walls stand 10 m or more from
## the road edge), hence this table. The walls stand 2 m from the road edge, the closest the
## barrier code allows (the kerbs need 1.8 m); the real ones are at the white line on most of
## the lap. Three places have an asphalt run-off in reality and get one here: straight on at
## Turn 1, the escape road of Turn 7, and the painted apron outside the last two corners
## (Commons: "Singapore Race Course viewed from Singapore Flyer", "Preparations for the 2023
## Singapore Grand Prix - BugWarp 09"); their depths are estimates from those photographs.
## The escape roads of Turns 8, 14 and 16 are not modelled.
## Kerb positions are generic (apex kerbs everywhere, exit kerbs after the slow corners), not
## surveyed.
##
## Sides: "in" = inside of the corner, "out" = outside. Offsets are metres along the lap from
## the apex (negative = before the apex).

## [turn id, side, from, to, kind]   kind: flat | saw | sausage
const KERBS: Array = [
	["T1", "in", -15.0, 15.0, "saw"],
	["T2", "in", -15.0, 15.0, "saw"],
	["T3", "in", -15.0, 15.0, "saw"],
	["T3", "out", 10.0, 40.0, "flat"],
	["T4", "in", -20.0, 20.0, "flat"],
	["T5", "in", -18.0, 18.0, "saw"],
	["T5", "out", 12.0, 45.0, "flat"],
	["T6", "in", -20.0, 20.0, "flat"],
	["T7", "in", -15.0, 15.0, "saw"],
	["T7", "out", 10.0, 40.0, "flat"],
	["T8", "in", -15.0, 15.0, "saw"],
	["T8", "out", 10.0, 40.0, "flat"],
	["T9", "in", -15.0, 15.0, "saw"],
	["T9", "out", 10.0, 40.0, "flat"],
	["T10", "in", -15.0, 15.0, "saw"],
	["T10", "out", 10.0, 40.0, "flat"],
	["T11", "in", -15.0, 15.0, "saw"],
	["T12", "in", -15.0, 15.0, "saw"],
	["T13", "in", -15.0, 15.0, "saw"],
	["T13", "out", 10.0, 40.0, "flat"],
	["T14", "in", -15.0, 15.0, "saw"],
	["T14", "out", 10.0, 40.0, "flat"],
	["T15", "in", -20.0, 20.0, "flat"],
	["T16", "in", -15.0, 15.0, "saw"],
	["T17", "in", -15.0, 15.0, "saw"],
	["T17", "out", 10.0, 40.0, "flat"],
	["T18", "in", -15.0, 15.0, "saw"],
	["T19", "in", -15.0, 15.0, "saw"],
	["T19", "out", 10.0, 40.0, "flat"],
]

## [turn id, side, from, to, kind, u_from, u_to]   kind: tarmac | gravel
## u is metres outward measured from the outer edge of any kerb there (0 = right behind it).
const RUNOFF: Array = [
	["T1", "out", -40.0, 20.0, "tarmac", 0.0, 10.0],
	["T7", "out", -35.0, 12.0, "tarmac", 0.0, 8.0],
	["T18", "out", -20.0, 45.0, "tarmac", 0.0, 10.0],
	["T19", "out", -40.0, 25.0, "tarmac", 0.0, 10.0],
]

## Barrier distance from the road edge (m) before clamping to the local geometry.
const BARRIER_STRAIGHT: float = 2.0
const BARRIER_CORNER_OUTSIDE: float = 2.5
const BARRIER_BEHIND_RUNOFF: float = 0.0

## Concrete wall + debris fence round the whole lap.
const CONCRETE_RANGES: Array = [[0.0, -0.001]]   # wraps: from the line round to just before it

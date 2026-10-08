extends RefCounted
## Trackside table of the Marina Bay Street Circuit, loaded by track id by TracksideLayout
## (scripts/track/trackside_layout.gd; format: see red_bull_ring.gd).
##
## A street circuit: concrete walls with debris fences right beside the road all the way
## round, no gravel and no run-off areas. The automatic layout cannot do that (its walls stand
## 10 m or more from the road edge), hence this table. The walls stand 2.5 m from the road
## edge, which leaves room for the kerbs (1.8 m at most); the real ones are at the white line
## on most of the lap, and the real escape roads (Turns 1, 7, 8, 14, 16) are not modelled.
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

## No run-off areas.
const RUNOFF: Array = []

## Barrier distance from the road edge (m) before clamping to the local geometry.
const BARRIER_STRAIGHT: float = 2.5
const BARRIER_CORNER_OUTSIDE: float = 3.0
const BARRIER_BEHIND_RUNOFF: float = 0.0

## Concrete wall + debris fence round the whole lap.
const CONCRETE_RANGES: Array = [[0.0, -0.001]]   # wraps: from the line round to just before it

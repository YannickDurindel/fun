extends RefCounted
## Hand-made trackside table of the Jeddah Corniche Circuit, loaded by track id by
## TracksideLayout (scripts/track/trackside_layout.gd); the format is that of red_bull_ring.gd.
## Everything is relative to the turn table in track.json.
##
## Why a table: the automatic layout puts barriers 10 to 20 m from the road and gravel outside
## the corners. Jeddah is a street circuit: concrete walls with debris fences stand right
## beside the road all the way round, and there is no gravel anywhere. So here the wall line
## is 2.5 m from the road edge (Trackside never brings it closer than 2 m), 3 m on the
## outside of corners, every wall is concrete, and the only run-off areas are the tarmac ones
## behind the two heavy braking zones (Turn 1 and Turn 27).
##
## The kerbs are a plain scheme, not a survey: a flat kerb on the inside of every numbered
## turn, sawtooth kerbs in the three slow corners, and exit kerbs where the lap opens onto a
## straight. All of them are narrower than the space in front of the wall.

## [turn id, side, from, to, kind]   kind: flat | saw | sausage
const KERBS: Array = [
	["T1", "in", -18.0, 16.0, "saw"],
	["T2", "in", -16.0, 22.0, "saw"],
	["T2", "out", 25.0, 70.0, "flat"],
	["T3", "in", -25.0, 25.0, "flat"],
	["T4", "in", -25.0, 20.0, "flat"],
	["T5", "in", -20.0, 30.0, "flat"],
	["T6", "in", -25.0, 25.0, "flat"],
	["T7", "in", -20.0, 20.0, "flat"],
	["T8", "in", -20.0, 25.0, "flat"],
	["T9", "in", -25.0, 20.0, "flat"],
	["T10", "in", -20.0, 25.0, "flat"],
	["T11", "in", -20.0, 20.0, "flat"],
	["T12", "in", -20.0, 20.0, "flat"],
	["T13", "in", -45.0, 45.0, "flat"],
	["T13", "out", 50.0, 110.0, "flat"],
	["T14", "in", -25.0, 25.0, "flat"],
	["T15", "in", -25.0, 25.0, "flat"],
	["T16", "in", -20.0, 15.0, "flat"],
	["T17", "in", -15.0, 25.0, "flat"],
	["T18", "in", -30.0, 30.0, "flat"],
	["T19", "in", -25.0, 25.0, "flat"],
	["T20", "in", -25.0, 25.0, "flat"],
	["T21", "in", -25.0, 25.0, "flat"],
	["T22", "in", -25.0, 25.0, "flat"],
	["T23", "in", -25.0, 25.0, "flat"],
	["T24", "in", -25.0, 25.0, "flat"],
	["T24", "out", 30.0, 80.0, "flat"],
	["T25", "in", -30.0, 30.0, "flat"],
	["T26", "in", -30.0, 30.0, "flat"],
	["T27", "in", -30.0, 25.0, "saw"],
	["T27", "out", 20.0, 80.0, "flat"],
]

## [turn id, side, from, to, kind, u_from, u_to]   kind: tarmac | gravel
## u is metres outward measured from the outer edge of any kerb there (0 = right behind it).
const RUNOFF: Array = [
	["T1", "out", -70.0, 15.0, "tarmac", 0.0, 12.0],
	["T27", "out", -80.0, 30.0, "tarmac", 0.0, 14.0],
]

## Barrier distance from the road edge (m) before clamping to the local geometry.
const BARRIER_STRAIGHT: float = 2.5
const BARRIER_CORNER_OUTSIDE: float = 3.0
## Space kept between the outer edge of a run-off area and the barrier line.
const BARRIER_BEHIND_RUNOFF: float = 1.0

## Concrete wall + debris fence: [from_s, to_s] absolute. The whole lap.
const CONCRETE_RANGES: Array = [[0.0, 6173.0]]

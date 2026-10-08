extends RefCounted
## Hand-made trackside table of the Las Vegas Strip Circuit, loaded by track id by
## TracksideLayout (scripts/track/trackside_layout.gd); see red_bull_ring.gd for the format.
##
## A street circuit: concrete walls with debris fences all the way round, 2.5 m from the road
## edge (the automatic layout keeps its barriers at least 10 m out and would line the Strip
## with armco and gravel). Low flat kerbs on the corners, no gravel anywhere. Tarmac escape
## areas where the real street carries straight on behind the big braking zones: Turn 1 (the
## paved lot behind the hairpin), Turn 5 (Koval Lane), Turn 12 (Spring Mountain Road) and
## Turn 14 (the Strip).
##
## Everything is relative to the turn table in track.json. Sides: "in" = inside of the
## corner, "out" = outside. Offsets are metres along the lap from the apex.

## [turn id, side, from, to, kind]   kind: flat | saw | sausage
const KERBS: Array = [
	["T1", "in", -30.0, 35.0, "flat"],
	["T2", "out", 10.0, 60.0, "flat"],
	["T3", "in", -30.0, 30.0, "flat"],
	["T4", "in", -25.0, 25.0, "flat"],
	["T5", "in", -20.0, 20.0, "flat"],
	["T5", "out", 10.0, 50.0, "flat"],
	["T7", "in", -18.0, 18.0, "flat"],
	["T8", "in", -18.0, 18.0, "flat"],
	["T9", "in", -20.0, 20.0, "flat"],
	["T9", "out", 10.0, 50.0, "flat"],
	["T12", "in", -22.0, 22.0, "flat"],
	["T12", "out", 10.0, 55.0, "flat"],
	["T14", "in", -22.0, 22.0, "flat"],
	["T16", "in", -22.0, 22.0, "flat"],
	["T16", "out", 10.0, 55.0, "flat"],
	["T17", "in", -25.0, 25.0, "flat"],
]

## [turn id, side, from, to, kind, u_from, u_to]   kind: tarmac | gravel
## u is metres outward measured from the outer edge of any kerb there (0 = right behind it).
const RUNOFF: Array = [
	["T1", "out", -70.0, 5.0, "tarmac", 0.0, 16.0],
	["T5", "out", -60.0, 5.0, "tarmac", 0.0, 12.0],
	["T12", "out", -60.0, 5.0, "tarmac", 0.0, 12.0],
	["T14", "out", -80.0, 5.0, "tarmac", 0.0, 14.0],
]

## Barrier distance from the road edge (m) before clamping to the local geometry.
const BARRIER_STRAIGHT: float = 2.5
const BARRIER_CORNER_OUTSIDE: float = 3.0
## Space kept between the outer edge of a run-off area and the barrier line.
const BARRIER_BEHIND_RUNOFF: float = 1.5

## Concrete wall + debris fence: [from_s, to_s] absolute. Two overlapping ranges = the lap.
const CONCRETE_RANGES: Array = [[0.0, 3200.0], [3100.0, 100.0]]

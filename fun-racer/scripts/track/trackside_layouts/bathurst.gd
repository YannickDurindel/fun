extends RefCounted
## Hand-made trackside table of Mount Panorama (Bathurst), loaded by track id by TracksideLayout.
## Format: see red_bull_ring.gd.
##
## Why a table: the automatic layout puts gravel and armco 10 m out. Mount Panorama is a public
## road with concrete walls right beside it from Hell Corner to Murrays Corner (a metre or two
## beyond the white line), no gravel on the mountain, and red / white kerbs at the corners.
## Estimates from the circuit's general character, not surveyed.
##
## Sides: "in" = inside of the corner, "out" = outside. Offsets are metres along the lap from
## the apex (negative = before the apex).

## [turn id, side, from, to, kind]   kind: flat | saw | sausage
const KERBS: Array = [
	["T1", "in", -30.0, 30.0, "saw"],
	["T2", "in", -25.0, 25.0, "flat"],
	["T3", "in", -20.0, 20.0, "flat"],
	["T4", "in", -25.0, 25.0, "saw"],
	["T5", "in", -25.0, 25.0, "flat"],
	["T6", "in", -25.0, 25.0, "flat"],
	["T10", "in", -30.0, 30.0, "flat"],
	["T13", "in", -20.0, 20.0, "saw"],
	["T14", "in", -20.0, 20.0, "saw"],
	["T15", "in", -20.0, 20.0, "saw"],
	["T18", "in", -30.0, 30.0, "saw"],
	["T18", "out", 10.0, 50.0, "flat"],
	["T21", "in", -30.0, 30.0, "saw"],
	["T22", "in", -25.0, 25.0, "flat"],
	["T23", "in", -35.0, 35.0, "saw"],
	["T23", "out", 10.0, 60.0, "flat"],
]

## [turn id, side, from, to, kind, u_from, u_to]
const RUNOFF: Array = [
]

## Walls stand close: the minimum the layout allows (2 m beyond the road edge).
const BARRIER_STRAIGHT: float = 2.0
const BARRIER_CORNER_OUTSIDE: float = 2.5
const BARRIER_BEHIND_RUNOFF: float = 2.0

## Concrete wall + debris fence all round the lap.
const CONCRETE_RANGES: Array = [[0.0, 6212.5]]

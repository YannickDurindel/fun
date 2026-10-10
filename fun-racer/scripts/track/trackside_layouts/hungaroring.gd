extends RefCounted
## Hand-made trackside table of the Hungaroring (2025 state: new pit building and main
## grandstand), loaded by track id by TracksideLayout (scripts/track/trackside_layout.gd).
## Format: see red_bull_ring.gd.
##
## Why a table: the automatic layout puts gravel outside most corners and its walls 10 to 20 m
## out. The Hungaroring has tarmac run-off outside nearly every corner, gravel only at the
## chicane and outside Turn 10, and a pit straight closed in by the pit wall and the wall
## under the main grandstand.
##
## Source for every extent: Esri World Imagery (2025, 0.4 m per pixel), measured along and
## across the centreline to about +/- 5 m; kerbs red and white all round the lap. Not
## surveyed.
##
## Everything is RELATIVE to the turn table in track.json (turns[i].s_apex, direction).
## Sides: "in" = inside of the corner, "out" = outside. Offsets are metres along the lap from
## the apex (negative = before the apex).

## [turn id, side, from, to, kind]   kind: flat | saw | sausage
const KERBS: Array = [
	["T1", "out", -70.0, -30.0, "flat"],     # turn-in kerb on the left at the end of the straight
	["T1", "in", -30.0, 28.0, "saw"],
	["T1", "out", 10.0, 85.0, "saw"],
	["T2", "in", -38.0, 35.0, "saw"],
	["T2", "out", 25.0, 95.0, "saw"],
	["T3", "in", -25.0, 25.0, "saw"],
	["T3", "out", 10.0, 70.0, "saw"],
	["T4", "in", -22.0, 25.0, "saw"],
	["T4", "out", 10.0, 75.0, "saw"],
	["T5", "in", -45.0, 40.0, "saw"],
	["T5", "out", 35.0, 115.0, "saw"],
	["T6", "out", -45.0, -15.0, "flat"],
	["T6", "in", -14.0, 12.0, "saw"],
	["T6", "in", -8.0, 8.0, "sausage"],      # the chicane cannot be cut
	["T7", "in", -12.0, 15.0, "saw"],
	["T7", "in", -8.0, 8.0, "sausage"],
	["T7", "out", 10.0, 55.0, "saw"],
	["T8", "in", -25.0, 25.0, "saw"],
	["T8", "out", 10.0, 60.0, "saw"],
	["T9", "in", -30.0, 30.0, "saw"],
	["T9", "out", 15.0, 85.0, "saw"],
	["T10", "in", -30.0, 30.0, "flat"],
	["T11", "in", -35.0, 35.0, "saw"],
	["T11", "out", 20.0, 105.0, "saw"],
	["T12", "in", -20.0, 20.0, "saw"],
	["T12", "out", 8.0, 65.0, "saw"],
	["T13", "in", -40.0, 40.0, "saw"],
	["T13", "out", 30.0, 95.0, "saw"],
	["T14", "in", -60.0, 60.0, "saw"],
	["T14", "out", 50.0, 145.0, "saw"],
]

## [turn id, side, from, to, kind, u_from, u_to]   kind: tarmac | gravel
## u is metres outward measured from the outer edge of any kerb there (0 = right behind it).
const RUNOFF: Array = [
	# The pit lane and its apron, in front of the garages on the right of the straight: the
	# game has no pit lane, so it is a strip of tarmac from the pit entry to the pit exit.
	["T1", "in", -700.0, -300.0, "tarmac", 0.0, 22.0],
	["T1", "out", -80.0, 95.0, "tarmac", 0.0, 24.0],
	["T2", "out", -45.0, 85.0, "tarmac", 0.0, 22.0],
	["T3", "out", -55.0, 60.0, "tarmac", 0.0, 22.0],
	["T4", "out", -30.0, 70.0, "tarmac", 0.0, 22.0],
	["T5", "out", -70.0, 90.0, "tarmac", 0.0, 24.0],
	["T6", "out", -25.0, 30.0, "gravel", 2.0, 22.0],
	["T8", "out", -40.0, 50.0, "tarmac", 0.0, 20.0],
	["T9", "out", -40.0, 75.0, "tarmac", 0.0, 24.0],
	["T10", "out", -10.0, 110.0, "gravel", 2.0, 18.0],
	["T11", "out", -55.0, 95.0, "tarmac", 0.0, 24.0],
	["T12", "out", -50.0, 55.0, "tarmac", 0.0, 20.0],
	["T13", "out", -50.0, 85.0, "tarmac", 0.0, 18.0],
	["T14", "out", -60.0, 125.0, "tarmac", 0.0, 12.0],
]

## Barrier distance from the road edge (m) before clamping to the local geometry. The lap is
## narrow and the guard rails stand close: a strip of grass, then armco.
const BARRIER_STRAIGHT: float = 6.0
const BARRIER_CORNER_OUTSIDE: float = 12.0
## Space kept between the outer edge of a run-off area and the barrier line.
const BARRIER_BEHIND_RUNOFF: float = 3.0

## Concrete wall + debris fence: [from_s, to_s] absolute, wrapping through the finish line.
## The start / finish straight from the exit of Turn 14 to the braking zone of Turn 1, between
## the pit building and the grandstands. Armco with tyre walls everywhere else.
const CONCRETE_RANGES: Array = [[4130.0, 500.0]]

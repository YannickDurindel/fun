extends RefCounted
## Hand-made trackside table of Suzuka (Grand Prix circuit), loaded by track id by
## TracksideLayout (scripts/track/trackside_layout.gd). See red_bull_ring.gd for the format:
## everything is relative to the turn table of track.json.
##
## Sources for the per-corner choices:
##   * GSI seamless orthophoto (Geospatial Information Authority of Japan, 0.49 m per pixel):
##     where the ground beside the road is tarmac, gravel or grass, how deep each run-off is
##     and how far out the wall and the grandstands stand;
##   * OpenStreetMap natural=sand areas (the gravel traps: First and Second Curve, both sides of
##     the S Curves, Dunlop, Degner, 130R, the chicane and Last Curve);
##   * en.wikipedia "Suzuka International Racing Course": Dunlop's run-off was doubled from 12
##     to 25 m in 2002; 130R was rebuilt in 2003 with a tarmac strip before the gravel.
## Suzuka is an old, narrow circuit: the wall is about 4 m from the road on the straights
## (measured at s = 330, 2700 and 4600) and every grandstand stands right behind it, so each
## run-off below ends before the nearest stand of the map.
##
## Sides: "in" = inside of the corner, "out" = outside. Offsets are metres along the lap from
## the apex (negative = before the apex).

## [turn id, side, from, to, kind]   kind: flat | saw | sausage
const KERBS: Array = [
	["T1", "out", -90.0, -40.0, "flat"],     # turn-in kerb on the left at the end of the straight
	["T1", "in", -30.0, 35.0, "saw"],
	["T2", "in", -35.0, 40.0, "saw"],
	["T2", "out", 30.0, 110.0, "saw"],
	["T3", "in", -30.0, 25.0, "saw"],
	["T3", "out", 20.0, 60.0, "flat"],
	["T4", "in", -30.0, 25.0, "saw"],
	["T4", "out", 20.0, 60.0, "flat"],
	["T5", "in", -30.0, 25.0, "saw"],
	["T6", "in", -30.0, 40.0, "saw"],
	["T6", "out", 40.0, 110.0, "flat"],
	["T7", "in", -60.0, 30.0, "saw"],
	["T7", "out", 20.0, 95.0, "saw"],
	["T8", "in", -22.0, 18.0, "saw"],
	["T8", "out", 10.0, 60.0, "saw"],
	["T9", "in", -22.0, 18.0, "saw"],
	["T9", "out", 10.0, 70.0, "saw"],
	["T10", "in", -40.0, 30.0, "flat"],
	["T11", "out", -70.0, -30.0, "flat"],
	["T11", "in", -22.0, 22.0, "saw"],
	["T11", "in", -10.0, 10.0, "sausage"],
	["T11", "out", 10.0, 70.0, "saw"],
	["T12", "in", -40.0, 40.0, "flat"],
	["T13", "in", -45.0, 40.0, "saw"],
	["T13", "out", 30.0, 75.0, "flat"],
	["T14", "in", -45.0, 40.0, "saw"],
	["T14", "out", 30.0, 110.0, "saw"],
	["T15", "in", -40.0, 40.0, "flat"],
	["T15", "out", 30.0, 100.0, "flat"],
	["T16", "in", -18.0, 16.0, "saw"],
	["T16", "in", -8.0, 8.0, "sausage"],
	["T17", "in", -16.0, 18.0, "saw"],
	["T17", "in", -8.0, 8.0, "sausage"],
	["T17", "out", 12.0, 50.0, "saw"],
	["T18", "in", -30.0, 60.0, "saw"],
	["T18", "out", 60.0, 150.0, "saw"],
]

## [turn id, side, from, to, kind, u_from, u_to]   kind: tarmac | gravel
## u is metres outward measured from the outer edge of any kerb there (0 = right behind it).
const RUNOFF: Array = [
	# First Curve: a strip of grass, then gravel. Second Curve: tarmac, then gravel.
	["T1", "out", -40.0, 60.0, "gravel", 1.5, 22.0],
	["T2", "out", -40.0, 120.0, "tarmac", 0.0, 16.0],
	["T2", "out", -40.0, 120.0, "gravel", 16.0, 27.0],
	# S Curves, Gyaku Bank: gravel on the outside of each bend, the stands right behind it.
	["T3", "out", 5.0, 130.0, "gravel", 3.0, 24.0],
	["T4", "out", -45.0, 85.0, "gravel", 2.0, 11.0],
	["T5", "out", -40.0, 105.0, "gravel", 2.0, 17.0],
	["T6", "out", 15.0, 180.0, "gravel", 1.0, 18.0],
	# Dunlop: 25 m since 2002, and the gravel goes on over the crest where the East Course
	# turns off.
	["T7", "out", -140.0, 100.0, "gravel", 1.5, 22.0],
	["T7", "out", 100.0, 270.0, "gravel", 3.0, 24.0],
	# Degner 1 and 2: gravel from the kerb to the tyre wall.
	["T8", "out", 12.0, 138.0, "gravel", 1.0, 24.0],
	["T9", "out", -16.0, 70.0, "gravel", 1.5, 20.0],
	# Hairpin: tarmac on the way in, a narrow band of gravel before the stand.
	["T11", "out", -45.0, 45.0, "tarmac", 0.0, 7.0],
	["T11", "out", -40.0, 45.0, "gravel", 7.0, 11.5],
	# Spoon: tarmac all the way round the outside, gravel behind it at the exit.
	["T13", "out", -80.0, 68.0, "tarmac", 0.0, 18.0],
	["T14", "out", -68.0, 100.0, "tarmac", 0.0, 20.0],
	["T14", "out", -20.0, 85.0, "gravel", 20.0, 25.0],
	# 130R: a tarmac strip, then the deepest gravel trap of the lap.
	["T15", "out", -10.0, 185.0, "tarmac", 0.0, 8.0],
	["T15", "out", -10.0, 185.0, "gravel", 8.0, 27.0],
	# Chicane: a gravel strip on the left on the way in, the painted tarmac escape road
	# straight on, gravel outside the second part and all round the outside of Last Curve.
	["T16", "out", -240.0, -85.0, "gravel", 2.0, 8.0],
	["T16", "out", -45.0, 45.0, "tarmac", 0.0, 15.0],
	["T17", "out", -5.0, 52.0, "gravel", 2.0, 18.0],
	["T18", "out", -22.0, 175.0, "gravel", 3.0, 14.0],
	# The pit lane, from the pit entry beside Last Curve to the pit exit at s = 415: tarmac
	# from the pit wall (a solid of the recipe's [[surroundings.add]], 9.3 to 9.9 m from the
	# centreline) to about 22 m; the barrier line it pushes out lands at about 24.5 m, just in
	# front of the garages (25 m).
	["T18", "in", 150.0, 720.0, "tarmac", 2.0, 11.5],
]

## Barrier distance from the road edge (m) before clamping to the local geometry.
const BARRIER_STRAIGHT: float = 4.0
const BARRIER_CORNER_OUTSIDE: float = 8.0
## Space kept between the outer edge of a run-off area and the barrier line.
const BARRIER_BEHIND_RUNOFF: float = 3.0

## Concrete wall + debris fence: the pit straight from the exit of Last Curve to the pit exit
## (both sides). The S Curves keep armco: a range cannot pick one side, and the side without
## stands has armco. Armco with tyre stacks everywhere else. [from_s, to_s] absolute,
## wrapping through the finish line.
const CONCRETE_RANGES: Array = [[5640.0, 420.0]]

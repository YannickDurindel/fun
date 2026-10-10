extends RefCounted
## Hand-made trackside table of the Bahrain International Circuit (Grand Prix layout), loaded
## by track id by TracksideLayout (scripts/track/trackside_layout.gd).
## Everything is expressed RELATIVE to the turn table in track.json (turns[i].s_apex,
## direction), so a re-fetched centreline keeps the kerbs on the right corners.
##
## Sources: aerial imagery (Esri World Imagery; SkySat image of 2 November 2017 on Wikimedia
## Commons) and the photograph of Turn 1 from the Sakhir Tower (Wikimedia Commons,
## "Bahrain-International-Circuit-curve-19-vip-tower").
##   * There is no gravel anywhere on the Grand Prix lap: every run-off is tarmac, most of it
##     painted. Outside the big braking zones it is 60 to 90 m deep; the road's verge is 30 m
##     wide, so here it ends at 27 m and the land cover carries on behind the barrier.
##   * At Turn 1 the tarmac starts at the kerb. Elsewhere a band of sand-coloured paint, 5 to
##     8 m wide, lies between the track and the dark tarmac: that band is the verge colour.
##   * Red and white kerbs on every apex and exit; the fast kinks (Turns 3, 5 and 12) have
##     flat ones.
##
## Sides: "in" = inside of the corner, "out" = outside. Offsets are metres along the lap from
## the apex (negative = before the apex).

## [turn id, side, from, to, kind]   kind: flat | saw | sausage
const KERBS: Array = [
	["T1", "out", -75.0, -30.0, "flat"],     # turn-in kerb on the left at the end of the pit straight
	["T1", "in", -22.0, 22.0, "saw"],
	["T1", "out", 8.0, 55.0, "saw"],
	["T2", "in", -25.0, 25.0, "saw"],
	["T2", "out", 15.0, 70.0, "saw"],
	["T3", "in", -30.0, 30.0, "flat"],
	["T4", "out", -70.0, -30.0, "flat"],
	["T4", "in", -28.0, 30.0, "saw"],
	["T4", "out", 20.0, 110.0, "saw"],       # the long exit kerb the cars run wide over
	["T5", "in", -30.0, 25.0, "flat"],
	["T6", "in", -30.0, 30.0, "saw"],
	["T6", "out", 25.0, 60.0, "flat"],
	["T7", "in", -35.0, 30.0, "saw"],
	["T7", "out", 25.0, 85.0, "saw"],
	["T8", "in", -25.0, 28.0, "saw"],
	["T8", "out", 15.0, 75.0, "saw"],
	["T9", "in", -35.0, 25.0, "flat"],
	["T10", "in", -18.0, 20.0, "saw"],
	["T10", "out", 10.0, 60.0, "saw"],
	["T11", "in", -40.0, 35.0, "saw"],
	["T11", "out", 30.0, 100.0, "saw"],
	["T12", "in", -40.0, 40.0, "flat"],
	["T13", "in", -40.0, 35.0, "saw"],
	["T13", "out", 30.0, 105.0, "saw"],
	["T14", "in", -25.0, 25.0, "saw"],
	["T14", "out", 15.0, 60.0, "saw"],
	["T15", "in", -25.0, 25.0, "flat"],
	["T15", "out", 20.0, 90.0, "saw"],       # exit kerb on the left onto the pit straight
]

## [turn id, side, from, to, kind, u_from, u_to]   kind: tarmac | gravel
## u is metres outward measured from the outer edge of any kerb there (0 = right behind it).
const RUNOFF: Array = [
	# Beside the First Turn grandstand (its front is 19 m from the road edge, up to 10 m
	# before the apex) the tarmac is a strip; the deep run-off opens beyond its north end (the barrier ramps out over the 30 m before it).
	["T1", "out", -150.0, 20.0, "tarmac", 0.0, 13.0],
	["T1", "out", 20.0, 85.0, "tarmac", 0.0, 27.0],
	["T2", "out", 5.0, 95.0, "tarmac", 2.0, 18.0],
	["T4", "out", -160.0, 60.0, "tarmac", 5.0, 27.0],
	["T4", "out", 60.0, 140.0, "tarmac", 5.0, 16.0],
	["T6", "out", -10.0, 70.0, "tarmac", 5.0, 16.0],
	["T7", "out", -10.0, 100.0, "tarmac", 5.0, 18.0],
	["T8", "out", -110.0, 70.0, "tarmac", 5.0, 27.0],
	["T10", "out", -150.0, 45.0, "tarmac", 5.0, 27.0],
	["T11", "out", -110.0, 120.0, "tarmac", 5.0, 27.0],
	["T12", "out", -10.0, 90.0, "tarmac", 5.0, 15.0],
	["T13", "out", -120.0, 110.0, "tarmac", 5.0, 27.0],
	["T14", "out", -120.0, 55.0, "tarmac", 3.0, 27.0],
	["T15", "out", 10.0, 80.0, "tarmac", 3.0, 14.0],
]

## Barrier distance from the road edge (m) before clamping to the local geometry.
const BARRIER_STRAIGHT: float = 9.0
const BARRIER_CORNER_OUTSIDE: float = 15.0
## Space kept between the outer edge of a run-off area and the barrier line.
const BARRIER_BEHIND_RUNOFF: float = 1.0

## Concrete wall + debris fence: [from_s, to_s] absolute, wrapping through the finish line.
## The pit straight (pit wall and the wall below the main grandstand) and the Turn 10 to
## Turn 11 straight, which runs along the drag strip. Armco everywhere else.
const CONCRETE_RANGES: Array = [[5038.0, 663.0], [2763.0, 3393.0]]

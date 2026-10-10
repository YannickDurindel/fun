extends RefCounted
## Hand-made trackside table of the Shanghai International Circuit (Grand Prix layout), loaded
## by track id by TracksideLayout (scripts/track/trackside_layout.gd). Same format as
## red_bull_ring.gd: everything is relative to the turn table in track.json.
##
## Source: Esri World Imagery (0.3 m pixels), read corner by corner against the built
## centreline, and photographs of the circuit on Wikimedia Commons.
##   * Kerbs are red and white everywhere. The inside kerb of the turn 1-2 spiral is one
##     piece 300 m long, and so is the outside kerb of turn 13 onto the back straight.
##   * Shanghai's run-offs are tarmac where the cars brake hardest or run wide at speed
##     (outside turns 1-2, 6, 7, 8, 9, 10, 11, the exit of 13, 14 and 16) and beige gravel
##     outside turns 3, 4, 12 and the first half of 13. The real areas are 40 to 100 m deep;
##     the road mesh carries a 30 m verge, so they are cut off at 16 to 26 m here.
##   * Armco on posts round most of the lap; a concrete wall with a debris fence along the
##     pit straight and between grandstands H and K at the turn 14 hairpin.
##
## Sides: "in" = inside of the corner, "out" = outside. Offsets are metres along the lap from
## the apex (negative = before the apex).

## [turn id, side, from, to, kind]   kind: flat | saw | sausage
const KERBS: Array = [
	["T1", "out", -180.0, -110.0, "flat"],   # turn-in kerb on the left, end of the pit straight
	["T1", "in", -55.0, 95.0, "saw"],        # the spiral's inside kerb, first half
	["T2", "in", -110.0, 45.0, "saw"],       # ... and second half
	["T3", "in", -48.0, 37.0, "saw"],
	["T3", "out", 22.0, 82.0, "saw"],
	["T4", "in", -40.0, 36.0, "saw"],
	["T4", "out", 16.0, 266.0, "flat"],      # long exit kerb on the right, up to turn 5
	["T5", "in", -40.0, 40.0, "saw"],
	["T5", "out", 70.0, 190.0, "flat"],
	["T6", "in", -30.0, 30.0, "saw"],
	["T6", "out", 25.0, 160.0, "saw"],
	["T7", "out", -153.0, -63.0, "flat"],
	["T7", "in", -53.0, 117.0, "saw"],
	["T8", "out", -242.0, -132.0, "flat"],
	["T8", "in", -92.0, 78.0, "saw"],
	["T9", "out", -82.0, -22.0, "flat"],
	["T9", "in", -27.0, 28.0, "saw"],
	["T9", "out", 23.0, 78.0, "saw"],
	["T10", "in", -27.0, 28.0, "saw"],
	["T10", "out", 18.0, 158.0, "saw"],
	["T11", "out", -83.0, -18.0, "flat"],
	["T11", "in", -33.0, 27.0, "saw"],
	["T12", "in", -31.0, 39.0, "saw"],
	["T12", "out", 19.0, 119.0, "saw"],
	["T13", "in", -34.0, 146.0, "saw"],
	["T13", "out", -14.0, 306.0, "saw"],     # outside kerb all the way onto the back straight
	["T14", "out", -112.0, -22.0, "flat"],
	["T14", "in", -22.0, 23.0, "saw"],
	["T14", "out", 18.0, 73.0, "saw"],
	["T15", "in", -24.0, 31.0, "saw"],
	["T16", "out", -110.0, -25.0, "flat"],
	["T16", "in", -30.0, 30.0, "saw"],
	["T16", "out", 15.0, 95.0, "saw"],
]

## [turn id, side, from, to, kind, u_from, u_to]   kind: tarmac | gravel
## u is metres outward measured from the outer edge of any kerb there (0 = right behind it).
const RUNOFF: Array = [
	["T1", "out", -60.0, 260.0, "tarmac", 0.0, 24.0],     # outside the whole spiral
	["T3", "out", -45.0, 70.0, "gravel", 2.0, 20.0],
	["T4", "out", -20.0, 90.0, "gravel", 2.0, 14.0],
	["T6", "out", -90.0, 70.0, "tarmac", 0.0, 26.0],
	["T7", "out", -60.0, 150.0, "tarmac", 0.0, 20.0],
	["T8", "out", -70.0, 100.0, "tarmac", 0.0, 22.0],
	["T9", "out", -30.0, 60.0, "tarmac", 0.0, 16.0],
	["T10", "out", -25.0, 70.0, "tarmac", 0.0, 16.0],
	["T11", "out", -100.0, 35.0, "tarmac", 0.0, 24.0],
	["T12", "out", -15.0, 100.0, "gravel", 2.0, 18.0],
	["T13", "out", -60.0, 110.0, "gravel", 2.0, 24.0],
	["T13", "out", 110.0, 300.0, "tarmac", 0.0, 20.0],
	["T14", "out", -120.0, 45.0, "tarmac", 0.0, 24.0],
	["T16", "out", -50.0, 80.0, "tarmac", 0.0, 16.0],
]

## Barrier distance from the road edge (m) before clamping to the local geometry. On the
## imagery the guard rail runs 8 to 13 m from the tarmac on the straights; the walls in front
## of the main grandstand and of stand H are nearer (4 to 5 m).
const BARRIER_STRAIGHT: float = 8.0
const BARRIER_CORNER_OUTSIDE: float = 16.0
## Space kept between the outer edge of a run-off area and the barrier line.
const BARRIER_BEHIND_RUNOFF: float = 3.0

## Concrete wall + debris fence: [from_s, to_s] absolute, wrapping through the finish line.
## Pit straight (turn 16 exit to the turn 1 braking zone) and the hairpin between stands H
## and K. Armco everywhere else.
const CONCRETE_RANGES: Array = [[5235.0, 480.0], [4450.0, 5160.0]]

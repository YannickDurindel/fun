extends RefCounted
## Hand-made trackside table of the Autódromo Hermanos Rodríguez (Grand Prix circuit, 2015
## layout with the Foro Sol), loaded by track id by TracksideLayout
## (scripts/track/trackside_layout.gd). See red_bull_ring.gd for the format.
##
## A permanent circuit that is walled in like a street circuit: it lies in a public park with
## grandstands, sports halls and the stadium a few metres from the road, so the automatic
## layout (gravel traps, barriers 10 to 30 m out) puts walls through the stands. What the
## aerial view (Esri World Imagery, 0.25 m per pixel) and onboard footage show instead:
##   * a concrete wall with a debris fence all round, 2.5 to 4 m from the white line on the
##     straights (pit wall and grandstand wall on the main straight);
##   * no gravel anywhere: every run-off is tarmac (Turn 1, Turn 4, the Horquilla, Turn 7,
##     Turn 10, Turn 12), painted in places;
##   * the Foro Sol is one sheet of tarmac from stand to stand: the road is only painted on
##     it, with the barriers some 10 m back on both sides (Turns 13 to 15);
##   * red and white kerbs on every apex and most exits, a yellow sausage kerb inside
##     Turn 2 and inside the stadium hairpin.
## The distances are limited by what really stands there (measured from the map): the stand
## over the track at the stadium exit leaves 5 m beside the road, the suites outside the
## Peraltada 5 m, the stands before Turn 1 10 m.
##
## Sides: "in" = inside of the corner, "out" = outside. Offsets are metres along the lap from
## the apex (negative = before the apex).

## [turn id, side, from, to, kind]   kind: flat | saw | sausage
const KERBS: Array = [
	["T1", "in", -20.0, 18.0, "saw"],
	["T1", "out", 10.0, 45.0, "flat"],
	["T2", "in", -15.0, 15.0, "saw"],
	["T2", "in", -8.0, 8.0, "sausage"],
	["T3", "in", -15.0, 15.0, "saw"],
	["T3", "out", 10.0, 55.0, "saw"],
	["T4", "in", -20.0, 18.0, "saw"],
	["T4", "out", 10.0, 40.0, "flat"],
	["T5", "in", -18.0, 18.0, "saw"],
	["T5", "out", 10.0, 50.0, "saw"],
	["T6", "in", -25.0, 22.0, "saw"],
	["T6", "out", 15.0, 60.0, "saw"],
	["T7", "in", -22.0, 22.0, "saw"],
	["T7", "out", 15.0, 55.0, "saw"],
	["T8", "in", -30.0, 30.0, "flat"],
	["T9", "in", -35.0, 35.0, "flat"],
	["T10", "in", -22.0, 22.0, "saw"],
	["T10", "out", 10.0, 45.0, "flat"],
	["T11", "in", -28.0, 28.0, "saw"],
	["T11", "out", 20.0, 70.0, "saw"],
	["T12", "in", -18.0, 18.0, "saw"],
	["T12", "out", 10.0, 45.0, "flat"],
	["T13", "in", -18.0, 18.0, "saw"],
	["T13", "in", -8.0, 8.0, "sausage"],
	["T14", "in", -15.0, 15.0, "saw"],
	["T15", "in", -12.0, 12.0, "flat"],
	["T16", "in", -20.0, 20.0, "saw"],
	["T16", "out", 10.0, 50.0, "saw"],
	["T17", "in", -50.0, 50.0, "flat"],
	["T17", "out", 40.0, 110.0, "flat"],
]

## [turn id, side, from, to, kind, u_from, u_to]   kind: tarmac | gravel
## u is metres outward measured from the outer edge of any kerb there (0 = right behind it).
const RUNOFF: Array = [
	["T1", "out", -5.0, 50.0, "tarmac", 0.0, 14.0],      # straight on at the end of the main straight
	["T4", "out", -60.0, 40.0, "tarmac", 0.0, 20.0],     # end of the back straight
	["T6", "out", -10.0, 40.0, "tarmac", 0.0, 9.0],      # Horquilla, in front of the grandstand
	["T7", "out", -20.0, 50.0, "tarmac", 0.0, 16.0],     # the painted run-off of the first Ese
	["T10", "out", -40.0, 40.0, "tarmac", 0.0, 14.0],
	["T12", "out", 15.0, 55.0, "tarmac", 0.0, 14.0],     # entry to the stadium
	["T13", "out", -130.0, 75.0, "tarmac", 0.0, 8.0],    # the stadium floor, both sides
	["T13", "in", -130.0, 75.0, "tarmac", 0.0, 8.0],
]

## Barrier distance from the road edge (m) before clamping to the local geometry.
const BARRIER_STRAIGHT: float = 3.0
## On the outside of a corner, from 60 m before the apex to 80 m after it.
const BARRIER_CORNER_OUTSIDE: float = 4.0
## Space kept between the outer edge of a run-off area and the barrier line.
const BARRIER_BEHIND_RUNOFF: float = 2.0

## Concrete wall + debris fence for the whole lap: two ranges [from_s, to_s] that meet at the
## finish line and at s = 3000, so nothing depends on the exact lap length.
const CONCRETE_RANGES: Array = [[0.0, 3000.0], [3000.0, 0.0]]

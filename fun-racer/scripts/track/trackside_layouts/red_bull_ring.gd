extends RefCounted
## Hand-made trackside table of the Red Bull Ring (2019-2024 layout), loaded by track id by
## TracksideLayout (scripts/track/trackside_layout.gd). A track without such a file gets the
## automatic layout instead.
## Everything is expressed RELATIVE to the turn table in track.json (turns[i].s_apex,
## direction), so a re-fetched centreline keeps the kerbs on the right corners.
##
## Sources for the per-corner choices (2019-2024 layout):
##   * yellow "sausage" kerbs behind the exits of T1, T3, T9 and T10 and inside T4;
##   * large tarmac run-off outside the heavy braking zones of T1, T3 and the entry of T4;
##   * gravel close to the track at the exits of T4, T6, T7 and T8 (FIA 2021/2024 changes);
##   * a 2.5 m gravel strip right behind the exit kerbs of T9 and T10 (2024), then tarmac.
##
## Sides: "in" = inside of the corner, "out" = outside. Offsets are metres along the lap from
## the apex (negative = before the apex).

## [turn id, side, from, to, kind]   kind: flat | saw | sausage
const KERBS: Array = [
	["T1", "out", -70.0, -32.0, "flat"],     # turn-in kerb on the left before Niki Lauda
	["T1", "in", -35.0, 25.0, "saw"],
	["T1", "out", 0.0, 70.0, "saw"],
	["T1", "out", 12.0, 60.0, "sausage"],
	["T2", "in", -30.0, 30.0, "flat"],
	["T3", "out", -60.0, -28.0, "flat"],
	["T3", "in", -30.0, 22.0, "saw"],
	["T3", "out", 0.0, 60.0, "saw"],
	["T3", "out", 12.0, 55.0, "sausage"],
	["T4", "in", -30.0, 45.0, "saw"],
	["T4", "in", -10.0, 30.0, "sausage"],
	["T4", "out", 30.0, 90.0, "saw"],
	["T5", "in", -25.0, 30.0, "flat"],
	["T5", "out", 15.0, 50.0, "flat"],
	["T6", "in", -30.0, 20.0, "saw"],
	["T6", "out", 5.0, 55.0, "saw"],
	["T7", "in", -35.0, 25.0, "saw"],
	["T7", "out", 10.0, 65.0, "saw"],
	["T8", "in", -25.0, 50.0, "saw"],
	["T8", "out", 40.0, 95.0, "saw"],
	["T9", "in", -30.0, 20.0, "saw"],
	["T9", "out", 0.0, 55.0, "saw"],
	["T9", "out", 12.0, 50.0, "sausage"],
	["T10", "in", -50.0, 10.0, "saw"],
	["T10", "out", -10.0, 45.0, "saw"],
	["T10", "out", 5.0, 40.0, "sausage"],
]

## [turn id, side, from, to, kind, u_from, u_to]   kind: tarmac | gravel
## u is metres outward measured from the outer edge of any kerb there (0 = right behind it).
const RUNOFF: Array = [
	["T1", "out", -60.0, 110.0, "tarmac", 0.0, 28.0],
	["T3", "out", -50.0, 100.0, "tarmac", 0.0, 26.0],
	["T4", "out", -90.0, 10.0, "tarmac", 0.0, 24.0],
	["T4", "out", 10.0, 110.0, "gravel", 1.5, 22.0],
	["T6", "out", 0.0, 90.0, "gravel", 1.5, 20.0],
	["T7", "out", 0.0, 100.0, "gravel", 1.5, 20.0],
	["T8", "out", 20.0, 120.0, "gravel", 1.5, 18.0],
	["T9", "out", -20.0, 80.0, "gravel", 0.0, 2.5],
	["T9", "out", -20.0, 80.0, "tarmac", 2.5, 20.0],
	["T10", "out", -20.0, 90.0, "gravel", 0.0, 2.5],
	["T10", "out", -20.0, 90.0, "tarmac", 2.5, 16.0],
]

## Barrier distance from the road edge (m) before clamping to the local geometry.
const BARRIER_STRAIGHT: float = 10.0
const BARRIER_CORNER_OUTSIDE: float = 15.0
## Space kept between the outer edge of a run-off area and the barrier line.
const BARRIER_BEHIND_RUNOFF: float = 5.0

## Concrete wall + debris fence (grandstands / pit straight): [from_s, to_s] absolute,
## wrapping through the finish line. Armco everywhere else.
const CONCRETE_RANGES: Array = [[4140.0, 330.0]]

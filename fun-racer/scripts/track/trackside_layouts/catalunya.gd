extends RefCounted
## Hand-made trackside table of the Circuit de Barcelona-Catalunya (Grand Prix layout since
## 2023), loaded by track id by TracksideLayout (scripts/track/trackside_layout.gd). See
## red_bull_ring.gd for the format.
##
## Source for every choice: the ICGC orthophoto (ortofoto_color_vigent, 25 cm, CC BY 4.0),
## straightened along the lap and measured from the road edge, checked against 2024 race
## photos (Wikimedia Commons "2024 Spanish Grand Prix") for kerbs and surfaces. What it shows:
##   * behind almost every exit kerb a strip of tarmac painted green (2 to 8 m), and behind it
##     the circuit's big, pale gravel traps (25 to 55 m deep at Elf, Renault, Repsol, Seat,
##     Campsa and the last three corners);
##   * a wall 6 m from the road along the main straight (grandstand side and pit wall) and in
##     front of the grandstands J, K, E and F before Elf; elsewhere armco.
## The automatic layout made the gravel traps 15 to 20 m deep and put the wall 10 m from the
## main straight. Kerb lengths are measured on the same photo to about +/- 5 m.
##
## Sides: "in" = inside of the corner, "out" = outside. Offsets are metres along the lap from
## the apex (negative = before the apex).

## [turn id, side, from, to, kind]   kind: flat | saw | sausage
## Red and white kerbs everywhere (no yellow sausages in the photos). Exit kerbs long on the
## outside of Elf, Renault, Repsol, Campsa and the last corner.
const KERBS: Array = [
	["T1", "in", -30.0, 22.0, "saw"],
	["T1", "out", 0.0, 75.0, "saw"],
	["T2", "in", -30.0, 25.0, "saw"],
	["T2", "out", 5.0, 50.0, "flat"],
	["T3", "in", -60.0, 60.0, "flat"],
	["T3", "out", 40.0, 150.0, "flat"],
	["T4", "in", -50.0, 40.0, "saw"],
	["T4", "out", 20.0, 120.0, "saw"],
	["T5", "in", -25.0, 25.0, "saw"],
	["T5", "out", 5.0, 60.0, "saw"],
	["T6", "in", -40.0, 40.0, "flat"],
	["T7", "in", -25.0, 20.0, "saw"],
	["T7", "out", 0.0, 45.0, "saw"],
	["T8", "in", -25.0, 25.0, "saw"],
	["T8", "out", 0.0, 45.0, "saw"],
	["T9", "in", -40.0, 30.0, "saw"],
	["T9", "out", 10.0, 90.0, "saw"],
	["T10", "in", -20.0, 15.0, "saw"],
	["T10", "out", -5.0, 50.0, "saw"],
	["T11", "in", -30.0, 30.0, "flat"],
	["T12", "in", -60.0, 40.0, "saw"],
	["T12", "out", 20.0, 110.0, "saw"],
	["T13", "in", -40.0, 30.0, "saw"],
	["T13", "out", 0.0, 80.0, "saw"],
	["T14", "in", -50.0, 40.0, "saw"],
	["T14", "out", 10.0, 120.0, "saw"],
]

## [turn id, side, from, to, kind, u_from, u_to]   kind: tarmac | gravel
## u is metres outward measured from the outer edge of any kerb there (0 = right behind it).
## Depths measured on the orthophoto from the road edge (the kerb is about 1.5 m of it).
const RUNOFF: Array = [
	["T1", "out", -60.0, 140.0, "tarmac", 0.0, 8.0],     # green tarmac, rebuilt 2023
	["T1", "out", -40.0, 130.0, "gravel", 8.0, 45.0],    # the trap reaches 50-60 m out
	["T2", "out", -20.0, 90.0, "gravel", 1.5, 18.0],
	["T3", "out", -30.0, 480.0, "gravel", 1.5, 36.0],    # all along Renault and the run to Repsol
	["T4", "out", -90.0, 0.0, "tarmac", 0.0, 10.0],
	["T4", "out", -60.0, 170.0, "gravel", 10.0, 48.0],
	["T5", "out", -60.0, 90.0, "gravel", 1.5, 32.0],
	["T7", "out", -60.0, 60.0, "gravel", 1.5, 30.0],
	["T8", "out", -10.0, 90.0, "gravel", 1.5, 14.0],
	["T9", "out", -90.0, 0.0, "tarmac", 0.0, 6.0],
	["T9", "out", -60.0, 110.0, "gravel", 6.0, 30.0],
	["T10", "out", -40.0, 70.0, "tarmac", 0.0, 9.0],     # green tarmac of the 2021 corner
	["T10", "out", -20.0, 70.0, "gravel", 9.0, 22.0],
	["T12", "out", -60.0, 110.0, "gravel", 1.5, 24.0],   # the stadium: stands G behind it
	["T13", "out", -50.0, 140.0, "gravel", 1.5, 27.0],
	["T14", "out", -60.0, 150.0, "gravel", 1.5, 32.0],
]

## Barrier distance from the road edge (m) before clamping to the local geometry. Measured:
## 6 m on the main and back straights, 8 to 20 m on the other straights.
const BARRIER_STRAIGHT: float = 7.0
const BARRIER_CORNER_OUTSIDE: float = 14.0
const BARRIER_BEHIND_RUNOFF: float = 4.0

## Concrete wall + debris fence: [from_s, to_s] absolute, wrapping through the finish line.
## The main straight from New Holland to Elf (grandstand, pit wall, stands J/K/E/F) and the
## stadium section in front of the stands B, G and C. Armco everywhere else.
const CONCRETE_RANGES: Array = [[4440.0, 790.0], [3700.0, 4120.0]]

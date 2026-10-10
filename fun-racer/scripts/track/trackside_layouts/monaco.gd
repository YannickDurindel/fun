extends RefCounted
## Hand-made trackside table of the Circuit de Monaco, loaded by track id by TracksideLayout
## (scripts/track/trackside_layout.gd). Format: see red_bull_ring.gd.
##
## A street circuit: no run-off anywhere, and the barrier stands beside the road for the whole
## lap. The automatic layout cannot do that (its walls stand 10 to 20 m out, behind gravel
## and tarmac run-off areas), which is why Monaco has a table. Trackside keeps every barrier
## at least 2 m from the road edge, and the table asks for exactly that everywhere: the real
## armco stands ON the kerb line, so 2 m is as close as the game gets. The strip between the
## white line and the wall LOOKS paved (environment.json "verge" colours it like the pavement
## the real barriers stand on), but it is still the road mesh's grass surface and grips like
## grass. The escape roads of Sainte Devote, Mirabeau and the chicane are not modelled.
##
## Everything is RELATIVE to the turn table in track.json (turns[i].s_apex, direction).
## Sides: "in" = inside of the corner, "out" = outside. Offsets are metres along the lap from
## the apex (negative = before the apex).

## [turn id, side, from, to, kind]   kind: flat | saw | sausage
## Apex kerbs where the real circuit has them; the chicanes also have the raised kerbs that
## stop the cars from cutting them. Not surveyed: lengths are estimates.
const KERBS: Array = [
	["T1", "in", -14.0, 14.0, "saw"],       # Sainte Devote
	["T1", "out", 8.0, 34.0, "flat"],
	["T3", "in", -20.0, 16.0, "flat"],      # Massenet
	["T4", "in", -14.0, 14.0, "saw"],       # Casino
	["T5", "in", -12.0, 12.0, "saw"],       # Mirabeau Haute
	["T6", "in", -9.0, 9.0, "saw"],         # Grand Hotel hairpin
	["T7", "in", -10.0, 10.0, "saw"],       # Mirabeau Bas
	["T8", "in", -10.0, 12.0, "saw"],       # Portier
	["T10", "in", -8.0, 8.0, "saw"],        # Nouvelle Chicane
	["T10", "in", -5.0, 5.0, "sausage"],
	["T11", "in", -8.0, 8.0, "saw"],
	["T11", "in", -5.0, 5.0, "sausage"],
	["T12", "in", -14.0, 14.0, "saw"],      # Tabac
	["T13", "in", -12.0, 10.0, "saw"],      # Louis Chiron
	["T14", "in", -10.0, 12.0, "saw"],
	["T15", "in", -8.0, 8.0, "saw"],        # Piscine
	["T15", "in", -5.0, 5.0, "sausage"],
	["T16", "in", -8.0, 8.0, "saw"],
	["T16", "in", -5.0, 5.0, "sausage"],
	["T18", "in", -10.0, 10.0, "saw"],      # La Rascasse
	["T19", "in", -10.0, 10.0, "saw"],      # Anthony Noghes
	["T19", "out", 6.0, 30.0, "flat"],
]

## No run-off areas.
const RUNOFF: Array = []

## Barrier distance from the road edge (m) before clamping to the local geometry.
const BARRIER_STRAIGHT: float = 2.0
const BARRIER_CORNER_OUTSIDE: float = 2.0
const BARRIER_BEHIND_RUNOFF: float = 5.0

## Concrete wall + debris fence: [from_s, to_s] absolute, wrapping through the finish line.
## The pit straight (Anthony Noghes to Sainte Devote), the tunnel (s = 1522 to 1885, with its
## approach and exit) and the harbour front from Tabac to La Rascasse, where the grandstands
## and the pit lane are. Armco everywhere else.
const CONCRETE_RANGES: Array = [[3050.0, 190.0], [1500.0, 1915.0], [2330.0, 2900.0]]

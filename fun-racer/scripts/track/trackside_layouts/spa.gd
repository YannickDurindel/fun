extends RefCounted
## Hand-made trackside table of the Circuit de Spa-Francorchamps (layout after the 2022 rebuild),
## loaded by track id by TracksideLayout (scripts/track/trackside_layout.gd). Format: see
## red_bull_ring.gd.
##
## Source of every entry: the orthophoto of the Service public de Wallonie, summer 2023, 25 cm
## (geoservices.wallonie.be, IMAGERIE/ORTHO_2023_ETE), straightened along the centreline of
## track.json, so positions along the lap are good to a few metres and widths to about 1 m.
## What it shows, and what the automatic layout got wrong:
##   * the armco stands 4 to 7 m from the white line on the straights (Kemmel, the run to
##     Pouhon, Blanchimont's inside), not 10 m, and the spruce begins right behind it;
##   * gravel came back in 2022: outside La Source, on the right of Les Combes and outside
##     Malmedy, behind the tarmac strip of Bruxelles, at Speaker's Corner, behind the tarmac
##     of Pouhon, at both Fagnes corners, all round Campus and Stavelot and outside Blanchimont;
##   * Eau Rouge / Raidillon and the chicane kept (painted) tarmac run-off;
##   * the kerbs are long and flat on the fast corners; raised kerbs only inside La Source,
##     the slow corners and the chicane.
## Not modelled: the tyre walls (every barrier here is armco or concrete), the paint of the
## tarmac run-off areas, the service roads behind the barriers, the link to the motorcycle
## chicane at Speaker's Corner (only its tarmac beside the track) and the pit lanes (their
## tarmac is part of the pit landmarks).
##
## Everything is RELATIVE to the turn table in track.json (turns[i].s_apex, direction).
## Sides: "in" = inside of the corner, "out" = outside. Offsets are metres along the lap from
## the apex (negative = before the apex).

## [turn id, side, from, to, kind]   kind: flat | saw | sausage
const KERBS: Array = [
	["T1", "in", -14.0, 24.0, "saw"],        # La Source apex
	["T1", "in", -6.0, 14.0, "sausage"],
	["T1", "out", -20.0, 165.0, "flat"],     # all round the outside, down to the pit exit
	["T2", "in", -15.0, 22.0, "saw"],        # Eau Rouge, left
	["T3", "in", -25.0, 80.0, "saw"],        # Raidillon, right
	["T4", "in", -155.0, 35.0, "flat"],      # the long left kerb up the hill to the crest
	["T4", "out", -25.0, 125.0, "flat"],     # exit on the right, over the crest
	["T5", "out", -125.0, -30.0, "flat"],    # turn-in kerb on the left at the end of Kemmel
	["T5", "in", -40.0, 45.0, "saw"],
	["T6", "in", -70.0, 40.0, "saw"],
	["T6", "out", 0.0, 90.0, "flat"],
	["T7", "in", -25.0, 30.0, "saw"],
	["T7", "out", 45.0, 160.0, "flat"],
	["T8", "out", -125.0, -60.0, "flat"],    # turn-in for Bruxelles
	["T8", "in", -75.0, 65.0, "saw"],
	["T8", "out", 65.0, 195.0, "flat"],
	["T9", "out", -90.0, -20.0, "flat"],     # turn-in for Speaker's Corner
	["T9", "in", -25.0, 40.0, "saw"],
	["T9", "out", 40.0, 135.0, "flat"],
	["T10", "out", -165.0, -110.0, "flat"],  # turn-in for Pouhon
	["T10", "in", -120.0, 35.0, "flat"],
	["T10", "out", 10.0, 160.0, "flat"],
	["T11", "in", -125.0, 10.0, "flat"],
	["T11", "out", 20.0, 120.0, "flat"],
	["T12", "out", -145.0, 55.0, "flat"],
	["T12", "in", -30.0, 40.0, "saw"],
	["T13", "in", -55.0, 45.0, "saw"],
	["T13", "out", 25.0, 105.0, "flat"],
	["T14", "out", -95.0, 135.0, "flat"],
	["T14", "in", -25.0, 35.0, "saw"],
	["T15", "in", -70.0, 115.0, "flat"],
	["T15", "out", 40.0, 490.0, "flat"],     # the long exit kerb of the Paul Frere curve
	["T17", "in", -50.0, 5.0, "flat"],
	["T17", "out", 35.0, 110.0, "flat"],
	["T18", "out", -95.0, 10.0, "flat"],     # braking for the chicane, left
	["T18", "in", -14.0, 14.0, "saw"],
	["T18", "in", -8.0, 8.0, "sausage"],
	["T19", "in", -16.0, 16.0, "saw"],
	["T19", "in", -8.0, 8.0, "sausage"],
	["T19", "out", 5.0, 75.0, "flat"],
]

## [turn id, side, from, to, kind, u_from, u_to]   kind: tarmac | gravel
## u is metres outward measured from the outer edge of any kerb there (0 = right behind it).
## The barrier stands BARRIER_BEHIND_RUNOFF + 2.5 m beyond u_to. The two 0.6 m strips marked
## "barrier line" are not run-off: they only set the distance of the barrier where grass
## reaches far out (they are the edge of the service road in front of it).
const RUNOFF: Array = [
	["T1", "out", -45.0, 10.0, "tarmac", 0.0, 14.0],       # painted tarmac straight on at La Source
	["T1", "out", 10.0, 165.0, "gravel", 0.5, 16.0],       # the gravel of 2022 round the exit
	["T1", "in", 25.0, 245.0, "tarmac", 0.0, 6.0],         # the F1 pit exit lane
	["T2", "in", -470.0, -50.0, "tarmac", 17.0, 17.6],     # barrier line: 20 m of grass on the left
	["T3", "out", -65.0, 80.0, "tarmac", 0.0, 22.0],       # Eau Rouge / Raidillon, left
	["T4", "in", -65.0, 165.0, "tarmac", 0.0, 19.0],       # the hill and the crest, left
	["T4", "out", -35.0, 215.0, "tarmac", 0.0, 20.0],      # over the crest, right
	["T5", "out", -10.0, 140.0, "tarmac", 0.0, 28.0],      # Les Combes straight on
	["T6", "out", -160.0, 180.0, "gravel", 0.5, 12.0],     # right of Les Combes
	["T7", "out", -10.0, 170.0, "gravel", 0.5, 18.0],      # outside Malmedy
	["T8", "out", -55.0, 165.0, "tarmac", 0.0, 9.0],       # Bruxelles: tarmac, then gravel
	["T8", "out", -35.0, 155.0, "gravel", 9.0, 24.0],
	["T9", "out", 25.0, 145.0, "gravel", 0.5, 6.0],        # Speaker's Corner exit
	["T9", "in", 45.0, 245.0, "tarmac", 0.0, 12.0],        # where the motorcycle link joins
	["T10", "out", -85.0, 270.0, "tarmac", 0.0, 11.0],     # Pouhon: tarmac, then a wide gravel bed
	["T10", "out", -75.0, 300.0, "gravel", 11.0, 40.0],
	["T11", "out", 45.0, 305.0, "tarmac", 0.0, 16.0],      # the exit of the Double Gauche
	["T11", "out", 85.0, 265.0, "gravel", 16.0, 24.0],
	["T12", "out", -90.0, 45.0, "gravel", 0.5, 28.0],      # Fagnes, first part
	["T13", "out", -115.0, 105.0, "gravel", 0.5, 16.0],    # Fagnes, second part
	["T14", "out", -55.0, 340.0, "gravel", 0.5, 24.0],     # Campus and Stavelot
	["T15", "out", 130.0, 540.0, "tarmac", 0.0, 10.0],     # Paul Frere exit: tarmac, then gravel
	["T15", "out", 130.0, 540.0, "gravel", 10.0, 24.0],
	["T16", "out", -45.0, 330.0, "tarmac", 0.0, 8.0],      # Blanchimont: tarmac, then gravel
	["T16", "out", -40.0, 330.0, "gravel", 8.0, 20.0],
	["T17", "out", -35.0, 260.0, "tarmac", 0.0, 8.0],
	["T17", "out", -35.0, 265.0, "gravel", 8.0, 22.0],
	["T18", "in", -230.0, -25.0, "tarmac", 19.0, 19.6],    # barrier line: the grass field on the right
	["T18", "out", -95.0, 55.0, "tarmac", 0.0, 11.0],      # painted tarmac left of the chicane
	["T19", "out", 0.0, 140.0, "tarmac", 0.0, 14.0],       # and on the right of its exit
]

## Barrier distance from the road edge (m) before clamping to the local geometry: the armco
## of the Kemmel straight stands 4 to 7 m from the edge, the one inside Blanchimont 7 m; the
## pit walls stand at the white line, so the lower figure is used everywhere.
const BARRIER_STRAIGHT: float = 4.0
const BARRIER_CORNER_OUTSIDE: float = 6.0
## The tyre walls stand right on the outer edge of the gravel.
const BARRIER_BEHIND_RUNOFF: float = 1.5

## Concrete wall + debris fence: [from_s, to_s] absolute, wrapping through the finish line.
## The Formula 1 pit straight with its grandstand (chicane exit to La Source) and the descent
## past the endurance pits and their grandstands to Eau Rouge. Armco everywhere else.
const CONCRETE_RANGES: Array = [[6740.0, 250.0], [440.0, 930.0]]

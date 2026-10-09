extends RefCounted
## Hand-made trackside table of the Autódromo José Carlos Pace (Interlagos), loaded by track id
## by TracksideLayout (scripts/track/trackside_layout.gd). Format: see red_bull_ring.gd.
##
## Why a table: the automatic layout puts gravel outside most corners and the walls 10 to 20 m
## out. Interlagos has no gravel beside the racing line at all: every run-off is tarmac
## (painted green and dark blue in reality, which the tarmac material cannot show), and the
## walls stand close, a few metres from the white line along the start straight, the Reta
## Oposta and the infield.
##
## Sources: Esri World Imagery (0.55 m per pixel) for the extent of every run-off and kerb,
## measured along the lap; the 2023 drone photographs "Vista aérea del Autódromo José Carlos
## Pace" 01 to 06 and "Topo do S de Interlagos" on Wikimedia Commons for the kerb types and
## the debris fences. Lengths are good to about 10 m, depths to about 3 m.
##
## Everything is RELATIVE to the turn table in track.json (turns[i].s_apex, direction).
## Sides: "in" = inside of the corner, "out" = outside. Offsets are metres along the lap from
## the apex (negative = before the apex).

## [turn id, side, from, to, kind]   kind: flat | saw | sausage
const KERBS: Array = [
	["T1", "in", -25.0, 20.0, "saw"],        # Senna S, first apex
	["T1", "in", -8.0, 8.0, "sausage"],
	["T1", "out", 18.0, 52.0, "saw"],
	["T2", "in", -20.0, 25.0, "saw"],        # Senna S, second apex
	["T2", "in", -8.0, 8.0, "sausage"],
	["T2", "out", 18.0, 60.0, "flat"],
	["T3", "in", -40.0, 40.0, "flat"],       # Curva do Sol: one long kerb inside
	["T3", "out", 60.0, 130.0, "flat"],
	["T4", "in", -25.0, 25.0, "saw"],        # Descida do Lago
	["T4", "out", 15.0, 70.0, "saw"],
	["T5", "in", -40.0, 50.0, "flat"],
	["T5", "out", 60.0, 140.0, "flat"],
	["T6", "in", -30.0, 40.0, "saw"],        # Ferradura
	["T7", "in", -30.0, 30.0, "saw"],        # Laranjinha
	["T7", "out", 25.0, 80.0, "saw"],
	["T8", "in", -25.0, 25.0, "saw"],        # the Esse before Pinheirinho
	["T8", "in", -8.0, 8.0, "sausage"],
	["T8", "out", 12.0, 50.0, "saw"],
	["T9", "in", -40.0, 40.0, "saw"],        # Pinheirinho
	["T9", "out", 35.0, 90.0, "saw"],
	["T10", "in", -20.0, 25.0, "saw"],       # Bico de Pato
	["T10", "in", -8.0, 8.0, "sausage"],
	["T10", "out", 15.0, 60.0, "saw"],
	["T11", "in", -60.0, 60.0, "flat"],      # Mergulho
	["T11", "out", 60.0, 120.0, "flat"],
	["T12", "in", -25.0, 25.0, "saw"],       # Junção
	["T12", "in", -8.0, 8.0, "sausage"],
	["T12", "out", 10.0, 70.0, "saw"],
	["T13", "in", -30.0, 30.0, "flat"],      # Café
	["T14", "in", -50.0, 50.0, "flat"],      # Subida dos Boxes
]

## [turn id, side, from, to, kind, u_from, u_to]   kind: tarmac | gravel
## u is metres outward measured from the outer edge of any kerb there (0 = right behind it).
const RUNOFF: Array = [
	# One row per continuous area: a row tapers to nothing at both of its ends.
	["T1", "out", -70.0, 140.0, "tarmac", 0.0, 27.0],    # the bowl outside the Senna S, as far as Curva do Sol
	["T3", "out", 310.0, 470.0, "tarmac", 0.0, 16.0],    # right of the start of the Reta Oposta
	["T4", "out", -20.0, 110.0, "tarmac", 0.0, 30.0],    # end of the Reta Oposta
	["T5", "out", -45.0, 110.0, "tarmac", 0.0, 14.0],
	["T6", "out", -40.0, 55.0, "tarmac", 0.0, 18.0],     # Ferradura
	["T7", "out", -45.0, 40.0, "tarmac", 0.0, 12.0],
	["T8", "out", -25.0, 40.0, "tarmac", 0.0, 12.0],
	["T10", "out", -20.0, 30.0, "tarmac", 0.0, 8.0],
	["T11", "out", -25.0, 80.0, "tarmac", 0.0, 15.0],    # Mergulho
	["T12", "out", -175.0, 40.0, "tarmac", 0.0, 22.0],   # the black apron on the way into Junção
]

## Barrier distance from the road edge (m) before clamping to the local geometry.
const BARRIER_STRAIGHT: float = 5.0
const BARRIER_CORNER_OUTSIDE: float = 12.0
## Space kept between the outer edge of a run-off area and the barrier line.
const BARRIER_BEHIND_RUNOFF: float = 4.0

## Concrete wall + debris fence: [from_s, to_s] absolute, wrapping through the finish line.
## From the scaffold stand on the Subida dos Boxes past the terraces, the pits and the roofed
## stands to the end of the Senna S; in front of sector R (Curva do Sol) and sector G (Reta
## Oposta). Armco everywhere else.
const CONCRETE_RANGES: Array = [[3600.0, 470.0], [540.0, 720.0], [880.0, 1260.0]]

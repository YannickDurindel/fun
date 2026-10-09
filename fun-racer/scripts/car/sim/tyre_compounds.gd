class_name SimTyreCompounds
extends RefCounted
## The tyre compound table. One row per compound; SimTyreCondition copies the active row into
## plain floats when the compound is chosen, so nothing here is read per tick.
##
## Every number is a DESIGN VALUE for the game, not measured tyre data. The shape follows what
## is publicly described of the real tyres: a softer slick grips more, works at a lower
## temperature, heats more easily and wears faster; a slick has very little grip on a wet
## road; the intermediate and the wet overheat and wear quickly on a dry one.
##
## Columns:
##   grip_dry / grip_damp / grip_wet  peak grip relative to a medium on a dry road, at
##                                    track_wetness 0, 0.5 and 1 (linear in between)
##   temp_low / temp_high             the working window (deg C); grip peaks at its centre
##   wear                             wear rate relative to the medium
##   heat                             heat generated relative to the medium
##   blanket                          temperature of a new set when fitted (deg C)

const SOFT: StringName = &"soft"
const MEDIUM: StringName = &"medium"
const HARD: StringName = &"hard"
const INTERMEDIATE: StringName = &"intermediate"
const WET: StringName = &"wet"

const DEFAULT: StringName = MEDIUM

## Soft to wet, the order used by menus.
const NAMES: Array[StringName] = [SOFT, MEDIUM, HARD, INTERMEDIATE, WET]

const TABLE: Dictionary = {
	SOFT: {"grip_dry": 1.035, "grip_damp": 0.70, "grip_wet": 0.40,
			"temp_low": 80.0, "temp_high": 110.0, "wear": 1.70, "heat": 1.10, "blanket": 70.0},
	MEDIUM: {"grip_dry": 1.000, "grip_damp": 0.68, "grip_wet": 0.40,
			"temp_low": 88.0, "temp_high": 118.0, "wear": 1.00, "heat": 1.00, "blanket": 70.0},
	HARD: {"grip_dry": 0.970, "grip_damp": 0.65, "grip_wet": 0.38,
			"temp_low": 96.0, "temp_high": 126.0, "wear": 0.65, "heat": 0.92, "blanket": 70.0},
	INTERMEDIATE: {"grip_dry": 0.860, "grip_damp": 0.84, "grip_wet": 0.70,
			"temp_low": 50.0, "temp_high": 80.0, "wear": 2.60, "heat": 1.30, "blanket": 60.0},
	WET: {"grip_dry": 0.800, "grip_damp": 0.80, "grip_wet": 0.78,
			"temp_low": 35.0, "temp_high": 65.0, "wear": 3.60, "heat": 1.50, "blanket": 40.0},
}

static func has(compound: StringName) -> bool:
	return TABLE.has(compound)

## The row of a compound (the medium's for an unknown name). Do not modify it.
static func row(compound: StringName) -> Dictionary:
	return TABLE[compound] if TABLE.has(compound) else TABLE[DEFAULT]

## Peak grip relative to a dry medium at the given track wetness (0 dry .. 1 standing water).
static func grip(compound: StringName, wetness: float) -> float:
	var r := row(compound)
	return grip_between(r["grip_dry"], r["grip_damp"], r["grip_wet"], wetness)

static func grip_between(dry: float, damp: float, wet: float, wetness: float) -> float:
	var w := clampf(wetness, 0.0, 1.0)
	if w < 0.5:
		return lerpf(dry, damp, w * 2.0)
	return lerpf(damp, wet, w * 2.0 - 1.0)

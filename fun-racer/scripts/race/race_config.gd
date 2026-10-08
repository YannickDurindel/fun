class_name RaceConfig
extends RefCounted
## What the player chose for one race. Edited by the menus (Game.pending), then handed to
## Game.start_race(); the race scene and its systems read Game.config.

const MODE_TIME_ATTACK := &"time_attack"   ## endless laps, chase your best
const MODE_RACE := &"race"                 ## ends after `laps` laps

var track_id: String = "red_bull_ring"
var mode: StringName = MODE_TIME_ATTACK
var laps: int = 3                ## used in MODE_RACE
var bots: int = 0                ## number of AI opponents (0 = none)
var bot_difficulty: int = 1      ## 0 easy, 1 medium, 2 hard
var ghost: bool = true           ## show the best-lap ghost car
var countdown: bool = true       ## 3-2-1-GO before the start
var camera: int = 1              ## starting camera: 1 low chase, 2 high chase, 3 cockpit

const KEYS: Array[StringName] = [&"track_id", &"mode", &"laps", &"bots", &"bot_difficulty", &"ghost", &"countdown", &"camera"]

func copy() -> RaceConfig:
	var c := RaceConfig.new()
	for k in KEYS:
		c.set(k, get(k))
	return c

func to_dict() -> Dictionary:
	var d := {}
	for k in KEYS:
		d[String(k)] = get(k)
	return d

func apply_dict(d: Dictionary) -> void:
	for k in KEYS:
		if d.has(String(k)):
			var v: Variant = d[String(k)]
			set(k, StringName(v) if k == &"mode" else v)
	laps = clampi(laps, 1, 99)
	bots = clampi(bots, 0, 7)
	bot_difficulty = clampi(bot_difficulty, 0, 2)
	camera = clampi(camera, 1, 3)

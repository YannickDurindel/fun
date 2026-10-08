# Fun Racer

A Trackmania-style racer for Linux, built with Godot 4.7. You drive a CAD-modelled F1 car on the
Red Bull Ring, rebuilt from open map and elevation data.

## Run the Red Bull Ring

Run everything from this folder (`fun-racer/`):

```bash
tools/get_godot.sh        # once: downloads Godot 4.7.2 (cached in ~/.cache/fun-racer)
tools/bin/godot --path .  # race the Red Bull Ring
```

A 3-2-1-GO countdown runs first, then the lap clock starts.

### Controls

| Action | Keyboard | Gamepad |
|---|---|---|
| Accelerate | Up / W | Right trigger |
| Brake / reverse | Down / S | Left trigger |
| Steer | Left, Right / A, D | Left stick |
| Respawn at the last checkpoint | Backspace / Enter | B |
| Restart the race from the grid | Delete | Back |
| Camera: low chase / high chase / cockpit | 1 / 2 / 3 | |

- **Steering is progressive on the keyboard.** Holding an arrow key turns the wheels further the
  longer you hold it, reaching full lock after about 0.4 s. A tap gives a small correction.
- **The car grips unless you ask it to slide.** To drift, hold brake and steer together for about
  0.3 s above 110 km/h. The drift ends shortly after you release the brake.
- **Respawn** puts you back at the last checkpoint with the speed you had there.

### Useful options

Add these after `--`:

```bash
tools/bin/godot --path . -- --no-countdown          # start driving immediately
tools/bin/godot --path . -- --spawn_s=1250          # spawn 1250 m into the lap (the climb to Remus)
tools/bin/godot --path . -- --autodrive             # watch the autopilot drive a lap
tools/bin/godot --path . -- --autodrive --camera=2  # same, from the high chase camera
```

`--spawn_s` takes a distance in metres from the finish line. Some landmarks: T1 Niki Lauda 454,
T3 Remus 1390 (top of the hill), T4 Schlossgold 2194, T6 Rauch 2804, T8 Rindt 3748,
T9 Red Bull Mobile 3982. The lap is 4318 m.

### Free roam

```bash
tools/bin/godot --path . res://scenes/main.tscn     # infinite flat plane, no track
```

## The track

- **Length and layout:** 4318 m and 10 turns. The centreline comes from OpenStreetMap and is scaled
  to the official lap length.
- **Elevation:** from the EU-DEM 25 m dataset. The lap has 68 m of elevation change and a climb of
  up to about 14 % to Remus.
- **Road:** 12.5–16 m wide with crossfall and light corner camber. Those widths and cambers are
  estimates, because no public source lists them per corner.
- **Trackside:** red/white and sausage kerbs, tarmac and gravel run-off, armco and concrete walls,
  and grass terrain with the surrounding hills.
- **Surfaces:** grass and gravel have less grip than tarmac and slow the car down.

## Tests and tools

```bash
tests/run_tests.sh                 # all headless tests (about 2.5 minutes)
tests/run_tests.sh --filter=car    # only test files whose name contains "car"
tools/lap_demo.sh                  # autopilot drives two full laps and prints speeds per turn
tools/screenshot.sh out.png        # render one frame of the race with the autopilot driving
tools/screenshot.sh out.png res://scenes/race_red_bull_ring.tscn 200 --spawn_s=1300
```

The autopilot's flying lap is currently about 1:16.7.

## Tuning the car

Open the project in the Godot editor (`tools/bin/godot --path . -e`), open `scenes/car/car.tscn`
and select the `Car` node. Every handling value is in the inspector, grouped by area. The ones
that matter most for feel:

- **Steering:** `key_steer_in_time` and `key_steer_out_time` set how fast keyboard steering builds
  and recentres.
- **Grip:** `lateral_grip_g` is cornering grip at low speed; `aero_grip_g` adds grip with speed.
- **Drift:** `drift_entry_time`, `drift_min_speed_kmh` and `drift_brake_release_time` set how hard
  a drift is to start and how soon it ends.

## Layout

- `scenes/race_red_bull_ring.tscn`: the race (main scene). `scenes/main.tscn`: free roam.
- `scripts/car/car.gd`: the car physics and the `Car` contract (speed, rpm, gear, inputs,
  `wheels: Array[WheelState]`) that the camera, HUD, audio and FX read.
- `scripts/track/track_data.gd`: `TrackData`, the centreline contract every track system reads.
  `scripts/track/road.gd` (`RoadSurface`) gives the exact road surface, width and banking.
- `scripts/race/`: race manager (countdown, checkpoints, laps, splits) and the autopilot.
- `assets/tracks/red_bull_ring/`: track data and generated meshes. Rebuild with
  `tools/track/fetch_red_bull_ring.py`, `tools/track/fetch_terrain.py` and `cad/track/road.py`.
- `cad/`: build123d sources for the car, wheels, road and trackside profiles. Set up with
  `python3 -m venv .venv && .venv/bin/pip install -r cad/requirements.txt`.
- `tests/`: `test_*.gd` files extend `TestCase` and run headless via `tests/runner.gd`.

## Data credits

Centreline © OpenStreetMap contributors (ODbL 1.0), relation 5309181. Elevation: EU-DEM v1.1
(Copernicus, © European Union) via OpenTopoData.

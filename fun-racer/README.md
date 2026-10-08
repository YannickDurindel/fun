# Fun Racer

A Trackmania-style racer for Linux, built with Godot 4.7. You drive a CAD-modelled F1 car on real
circuits rebuilt from open map and elevation data, starting with the Red Bull Ring: time attack
against your own ghost, or races against bots.

## Play

Run everything from this folder (`fun-racer/`):

```bash
tools/get_godot.sh        # once: downloads Godot 4.7.2 (cached in ~/.cache/fun-racer)
tools/bin/godot --path .  # start the game
```

The game opens on the main menu:

1. **Play** → choose a track. The Red Bull Ring is playable; the other F1 circuits are listed as
   coming soon.
2. **Race options** → mode (time attack with endless laps, or a race of 1–20 laps), opponents
   (off, or 1–7 bots at easy / medium / hard), ghost car, countdown and starting camera.
3. **Start race.** A loading screen shows the track while it builds.

Other menu entries: **Continue** restarts your last race, **Records** lists your best laps and
sectors per track, and **Options** holds graphics, audio, gameplay and controls.

### Controls

Every binding can be changed in Options → Controls. Defaults:

| Action | Keyboard | Gamepad |
|---|---|---|
| Accelerate | Up / W | Right trigger |
| Brake / reverse | Down / S | Left trigger |
| Steer | Left, Right / A, D | Left stick |
| Respawn at the last checkpoint | Backspace / Enter | B |
| Restart the race from the grid | Delete | Back |
| Pause | Esc | Start |
| Camera: low chase / high chase / cockpit | 1 / 2 / 3 | |

Key positions follow your keyboard layout (on AZERTY, W/A are Z/Q).

- **Steering is progressive on the keyboard.** Holding an arrow key turns the wheels further the
  longer you hold it, reaching full lock after about 0.4 s. A tap gives a small correction. The
  build-up and release times are sliders in Options → Controls.
- **The car grips unless you ask it to slide.** To drift, hold brake and steer together for about
  0.3 s above 110 km/h. The drift ends shortly after you release the brake.
- **Respawn** puts you back at the last checkpoint with the speed you had there.

### In a race

- **Pause (Esc):** resume, restart, options, back to track select or the main menu. In time
  attack it also offers End Session, which shows your results so far.
- **Race mode** ends after the chosen number of laps with a results screen: lap table, sectors,
  best lap and whether you set a new record.
- **Ghost car:** your best lap on each track is saved and replayed as a translucent car you can
  drive through. Autopilot laps are never saved.
- **Bots** are Trackmania-style: they race you but never collide with you. A standings panel
  shows your position and the gaps.

### Options

- **Graphics:** quality preset, fullscreen, resolution, vsync, FPS cap, anti-aliasing, shadows and
  render scale. The Low preset is meant for integrated graphics.
- **Audio:** master, engine, effects and menu volumes.
- **Gameplay:** km/h or mph, and the on-screen input display.
- **Controls:** rebinding, steering build-up and release, gamepad dead zone.

Settings are saved in Godot's user data folder (`~/.local/share/godot/app_userdata/Fun Racer/`),
together with your best laps and ghosts.

### Skipping the menu

Add flags after `--`:

```bash
tools/bin/godot --path . -- --track=red_bull_ring                      # straight into the race
tools/bin/godot --path . -- --track=red_bull_ring --mode=race --laps=3 --bots=7 --difficulty=2
tools/bin/godot --path . -- --track=red_bull_ring --no-countdown --spawn_s=1250   # start on the climb to Remus
tools/bin/godot --path . -- --track=red_bull_ring --autodrive --camera=2          # watch the autopilot
tools/bin/godot --path . -- --screen=settings                          # open the menu on one screen
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
tests/run_tests.sh                 # all headless tests (about 5 minutes)
tests/run_tests.sh --filter=car    # only test files whose name contains "car"
tools/lap_demo.sh                  # autopilot drives two full laps and prints speeds per turn
tools/screenshot.sh out.png        # render one frame of the main menu
tools/screenshot.sh out.png res://scenes/race.tscn 300 --track=red_bull_ring --spawn_s=1300
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

## Adding a track

A track is a folder under `assets/tracks/<id>/`. One command builds it from open map and
elevation data:

```bash
python3 -m venv .venv && .venv/bin/pip install -r cad/requirements.txt
.venv/bin/python tools/track/build_track.py <id> --osm-relation <OpenStreetMap relation id>
```

`tools/track/README.md` explains how to find the relation, what a recipe file can override
(start line, widths, banking, turn names) and what to check when the automatic detection is
wrong. Once the folder exists, the track appears in the menu as playable; kerbs, run-off and
walls are laid out automatically unless the track has a hand-made table in
`scripts/track/trackside_layouts/`. The circuits listed as coming soon are in
`assets/tracks/calendar.json`.

## Layout

- `scenes/menu/`: the menu shell (`menu.tscn`, the main scene) and one scene per screen.
  `scripts/menu/menu_router.gd` switches screens; screens extend `UIScreen`.
- `scripts/game.gd` (`Game` autoload): the flow between menu and race, and the `RaceConfig` the
  player chose. `scripts/settings.gd` (`Settings`): saved options. `scripts/settings_apply.gd`
  applies graphics and audio settings. `scripts/input_bindings.gd`: key and gamepad bindings.
- `scenes/race.tscn`: the race. It builds whichever track was chosen. `scenes/main.tscn`: free roam.
- `scripts/car/car.gd`: the car physics and the `Car` contract (speed, rpm, gear, inputs,
  `wheels: Array[WheelState]`) that the camera, HUD, audio and FX read.
- `scripts/track/`: `TrackCatalog` (the track list), `TrackData` (the centreline contract),
  `Track` and the generic road, terrain and trackside builders.
- `scripts/race/`: race manager (countdown, checkpoints, laps, splits, finish), autopilot, bots
  and the ghost recorder and player.
- `scripts/ui/`: HUD, race panel, standings, pause menu, results and loading screen.
- `assets/tracks/<id>/`: track data and generated meshes.
- `cad/`: build123d sources for the car, wheels, road and trackside profiles.
- `tests/`: `test_*.gd` files extend `TestCase` and run headless via `tests/runner.gd`.

## Data credits

Centreline © OpenStreetMap contributors (ODbL 1.0), relation 5309181. Elevation: EU-DEM v1.1
(Copernicus, © European Union) via OpenTopoData.

# Fun Racer

A Trackmania-style racer for Linux, built with Godot 4.7. You drive a CAD-modelled F1 car on real
circuits rebuilt from open map and elevation data, all 24 of the F1 calendar: time attack
against your own ghost, or races against bots.

## Play

Run everything from this folder (`fun-racer/`):

```bash
tools/get_godot.sh        # once: downloads Godot 4.7.2 (cached in ~/.cache/fun-racer)
tools/bin/godot --path .  # start the game
```

The game opens on the main menu:

1. **Play** → choose a track. All 24 circuits of the F1 calendar are playable.
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
- **A minimap** in the top right corner shows the circuit, the start line, your car (the red
  arrow) and the bots.
- **Analog steering can slide the car.** On a phone or a gamepad stick, holding the steering at
  its very end for about half a second above 60 km/h breaks the rear loose into a mild slide.
  Keys never do this.

### Handling: arcade or simulation

Options → Gameplay → **Handling** chooses the car's physics, from the next race:

- **Arcade** (default): the Trackmania-style car described above.
- **Simulation**: a force-based model with a combined-slip tyre model, suspension and load
  transfer, ground-effect aerodynamics with DRS and slipstream, a turbo-hybrid power unit with
  8 gears and energy deployment, brakes that lock, and tyre temperature, wear and fuel. It adds
  shift up (E / pad RB), shift down (Q / pad LB) and DRS (Space / pad X), and five driving aids
  in the same tab: traction control, ABS, automatic gearbox, steering help and stability help.
  F3 shows a telemetry overlay. It is experimental: it laps cleanly on autopilot but is not
  tuned to feel right yet. `--handling=simulation` on the command line forces it for one run.

### Phone controller

Your phone can be the steering wheel and the pedals. There is no app to install: the game serves
a web page over your Wi-Fi, and the phone sends its tilt and touches back about 60 times a second.

1. Put the phone and the PC on the **same Wi-Fi network**.
2. In **Options → Controls**, turn **Phone controller** on. The section opens and shows an
   address, a QR code and a 4-digit pairing code. (It is at the top of the screen; the screen
   scrolls.)
3. Scan the QR code with the phone's camera, or type the address (`http://<PC address>:8080`)
   in the phone's browser.
4. Type the pairing code on the phone. The status on the PC changes to "Phone connected".
5. Hold the phone in landscape, like a steering wheel, with the screen facing you:
   - **turn it** left and right to steer; press **CENTRE** while holding it level to set the
     straight-ahead position;
   - the **right side** of the screen is the gas button and the **left side** is the brake
     button: touching one anywhere is full pedal (add `?pedals=analog` to the address for
     pedals that follow the height of your thumb);
   - **AUTO GAS** accelerates for you, so you only steer and brake; **CAM** changes the view;
   - **− / +** shift gears and **DRS** opens the wing (simulation handling); **RESPAWN** and
     **PAUSE** are the small buttons at the top;
   - **TILT / TOUCH** switches to steering with a slider under your left thumb.

The page also shows speed and gear, and vibrates on gear shifts and kerbs (Android only).
Three sliders in the same section tune it: degrees of tilt for full lock (15–60°, default 30°),
dead zone and smoothing. Keyboard and gamepad keep working at the same time.

**Tilt steering needs Chrome and the secure address.** Use the `https://<PC address>:8443` address
(the second QR code) and accept the certificate warning once (Advanced → Proceed). Brave blocks
motion sensors by default: use Chrome, or allow "Motion sensors" for the page in Brave's site
settings. **AUTO GAS** in the top row makes the car accelerate by itself, so you only steer and
brake. Tilting all the way makes the car slide.

**If the phone cannot open the page,** the PC's firewall is probably blocking the port. The game
never changes your firewall; allow the port yourself. On Fedora:

```bash
sudo firewall-cmd --add-port=8080/tcp --add-port=8443/tcp   # until the next restart
```

If port 8080 is already taken, the game uses the next free one and shows it in the address.

**iPhone, and phones that report "Tilt needs the secure address".** Browsers only give motion
sensors to pages served over HTTPS (always on iOS, and on some Android browsers). The game
therefore serves the same page over HTTPS on port 8443, with a certificate it creates on your
PC the first time. Use the second address and QR code ("TILT STEERING (SECURE)", `https://<PC address>:8443`),
accept the browser's certificate warning once ("Show details" → "Visit this website" in Safari),
then allow "Motion & Orientation Access" when asked. Over the plain `http://` address such a
phone still works: the page says tilt is unavailable in one line and steers by touch instead.
This path has been tested with scripted clients only, not on a real iPhone.

Safety:

- The option is **off by default**, and nothing listens on the network while it is off.
- Nobody can drive without the pairing code. It changes every time the option is turned on,
  and five wrong codes lock the device that sent them out for a while. One phone is paired at
  a time.
- If the phone stops sending for 0.3 s (connection lost, browser in the background), the game
  releases throttle, brake and steering.
- The game only talks to devices on your network that connect to it. It never contacts the
  internet for this, and the page loads nothing from outside.

`--phone` (after `--`) starts the phone controller for one run without changing the saved option,
and prints the ports and the pairing code. The code is in `scripts/phone/` (server, WebSocket, QR encoder) and
`assets/phone/controller.html` (the page).

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

- **Graphics:** quality preset, fullscreen, resolution, vsync, FPS cap, anti-aliasing, shadows,
  scenery and render scale. The Low preset is meant for integrated graphics: it draws half the
  trees and none beyond 300 m, hides far skyline buildings and draws plain facades.
- **Audio:** master, engine, effects and menu volumes.
- **Gameplay:** km/h or mph, and the on-screen input display.
- **Controls:** the phone controller, rebinding, steering build-up and release, gamepad dead zone.

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

## The tracks

All 24 circuits are built by one pipeline (`tools/track/build_track.py`) from open data, each
from a recipe in `tools/track/tracks/<id>.toml`:

- **Layout:** the centreline comes from OpenStreetMap and is scaled to the official lap length.
- **Elevation:** from open elevation data (Terrain Tiles; the Dutch and French national ground
  models for Zandvoort and Monaco; EU-DEM for the Red Bull Ring).
- **Road:** widths and camber are estimates, because no public source lists them per corner.
  Street circuits use narrower roads.
- **Trackside:** kerbs, run-off and barriers. Permanent circuits get an automatic layout; the
  Red Bull Ring and the street circuits have hand-written ones, with walls close to the road
  on the street circuits.
- **Surfaces:** grass and gravel have less grip than tarmac and slow the car down.

Track ids for `--track=`: `albert_park`, `bahrain`, `baku`, `catalunya`, `cota`,
`gilles_villeneuve`, `hermanos_rodriguez`, `hungaroring`, `imola`, `interlagos`, `jeddah`,
`las_vegas`, `lusail`, `marina_bay`, `miami`, `monaco`, `monza`, `red_bull_ring`, `shanghai`,
`silverstone`, `spa`, `suzuka`, `yas_marina`, `zandvoort`.

Known limits: real banking has to be declared in a track's recipe and no track does yet
(Zandvoort's and Jeddah's banked corners are still nearly flat), there are no buildings, tunnels, overpasses or water, desert circuits have grass
verges, and short steep climbs come out gentler than in reality (Spa's Raidillon peaks at
12.8 % against about 18 %). Each recipe file records what was checked against a source and
what is an estimate.

## Scenery and time of day

A track's surroundings come from optional files in its folder (`assets/tracks/<id>/`). A track
without them looks as plain as before: one daytime sky and grass everywhere.

| File | What it gives |
|---|---|
| `landcover.png`, `landcover_far.png` | Ground types (grass, forest, water, sand, paved, farmland, rock, gravel, scrub, beach), painted by the terrain shader |
| `scenery.glb` | Buildings and grandstands in 400 m chunks; walls, windows, seats and crowds are drawn by shaders |
| `scenery_points.bin` | Trees (position, height, species) |
| `scenery.json` | The grids of the two PNGs, the tree record layout and the water bodies |
| `environment.json` | Hand-written look: time of day, sun, sky, fog, ground colours, kerb and verge colours, tree mix, floodlights |
| `landmarks.json` + `landmarks/*.glb` | Hand-placed landmark models |

The first four are baked from map data by the track pipeline; the last two are written by
hand. The exact formats are in the header comments of `scripts/track/scenery.gd` and
`scripts/track/track_environment.gd`.

### environment.json

Every key is optional. Start from a preset in `assets/tracks/_shared/environments/`
(`temperate_day`, `desert`, `floodlit_night`) and override what differs. Colours are
`[r, g, b]` from 0 to 1, or `"#rrggbb"`. A misspelt key prints a warning.

```json
{
 "preset": "temperate_day",
 "time": "day",
 "sun": {"azimuth_deg": 60, "elevation_deg": 45, "color": [1.0, 0.95, 0.86], "energy": 1.5},
 "sky": {"top": [0.24, 0.45, 0.78], "horizon": [0.74, 0.81, 0.88], "stars": 0.0,
         "glow_color": [0.90, 0.55, 0.25], "glow": 0.0},
 "ambient": {"color": [0.62, 0.64, 0.66], "energy": 1.0},
 "fog": {"color": [0.74, 0.81, 0.88], "begin": 250, "end": 2900},
 "exposure": 1.0,
 "glow": {"intensity": 0.35, "threshold": 1.1, "bloom": 0.03},
 "terrain_palette": {
  "grass": [[0.20, 0.35, 0.12], [0.29, 0.42, 0.15]],
  "forest": [[0.09, 0.17, 0.07], [0.13, 0.23, 0.09]],
  "water": [[0.08, 0.20, 0.24], [0.10, 0.24, 0.28]],
  "sand": [[0.74, 0.65, 0.46], [0.82, 0.74, 0.55]],
  "urban": [[0.40, 0.40, 0.41], [0.50, 0.49, 0.47]],
  "farmland": [[0.44, 0.47, 0.20], [0.62, 0.55, 0.30]],
  "rock": [[0.42, 0.40, 0.37], [0.55, 0.52, 0.48]],
  "gravel": [[0.52, 0.47, 0.39], [0.63, 0.58, 0.48]],
  "scrub": [[0.30, 0.35, 0.17], [0.42, 0.42, 0.24]],
  "beach": [[0.84, 0.78, 0.60], [0.90, 0.85, 0.70]]
 },
 "mowing_stripes": true,
 "verge": {"grass_color": [0.20, 0.36, 0.11], "dry_color": [0.33, 0.38, 0.16]},
 "kerbs": {"a": [0.78, 0.07, 0.06], "b": [0.93, 0.93, 0.91], "sausage": [0.95, 0.78, 0.05]},
 "trees": {
  "mix": {"conifer": 3, "broadleaf": 1},
  "colors": {"conifer": [[0.07, 0.17, 0.08], [0.13, 0.26, 0.11]]},
  "density": 1.0,
  "scale": 1.0
 },
 "floodlights": {"enabled": false, "spacing_m": 60, "height_m": 28,
                 "color": [1.0, 0.97, 0.90], "energy": 1.25, "reach_m": 90},
 "water": {"color": [0.10, 0.26, 0.32], "deep_color": [0.03, 0.10, 0.16]},
 "buildings": {"lit_windows": 0.35, "window_color": [1.0, 0.80, 0.52]},
 "stands": {"seat_colors": [[0.10, 0.25, 0.60], [0.75, 0.10, 0.10], [0.80, 0.80, 0.82]], "crowd": 0.6}
}
```

- `time` is `day`, `dusk` or `night`. Each time has stock lighting, used when `time` differs
  from the preset's; `sun`, `sky`, `ambient`, `fog`, `exposure` and `glow` in the file override
  it. At night `sun` describes the moon.
- `sun.azimuth_deg` is the compass bearing towards the sun (0 north, 90 east).
- `terrain_palette` gives two colours per ground type; the shader mixes them. The `grass`
  pair also colours the plain terrain of a track without land cover.
- `trees.mix` replaces the species in the baked data by a weighted mix of `conifer`,
  `broadleaf`, `palm`, `cypress` and `bush`. Leave it out (or `{}`) to keep the data's species.
- `floodlights.enabled` puts masts every `spacing_m` behind the barriers. At dusk and at night
  their lamps glow and the road, the cars and everything within about 160 m of the lap are lit;
  the ground is lit within `reach_m` of the centreline.

### landmarks.json

```json
[
 {"model": "casino", "at": {"latlon": [43.7392, 7.4277]}, "y_offset": 0.0, "yaw_deg": 90.0, "scale": 1.0},
 {"model": "gantry", "at": {"s": 120, "side": 1, "dist": 0}, "yaw_deg": 0.0},
 {"model": "tower", "at": {"xz": [350.0, -120.0]}}
]
```

`model` is a file in `assets/tracks/<id>/landmarks/` (`.glb` is added when missing). `at` is
one of: `latlon` (latitude, longitude; the model sits on the terrain), `xz` (track metres,
x east and z south; on the terrain), or `s` / `side` / `dist` (metres round the lap, +1 right
or -1 left, metres from the centreline; at road height, and `yaw_deg` 0 faces along the lap).
Surfaces named like the scenery materials (`building_wall`, `building_glass`, `concrete`,
`metal`, `emissive_light` ...) get the game's materials; any other material is kept.

### Looking at a track

```bash
tools/screenshot.sh "$PWD/shots/a.png" res://scenes/race.tscn 300 --track=monaco --spawn_s=1300 --camera=2
tools/screenshot.sh "$PWD/shots/b.png" res://scenes/race.tscn 300 --track=monaco --overview
tools/screenshot.sh "$PWD/shots/c.png" res://scenes/race.tscn 300 --track=monaco --time=night \
    --cam-pos=200,60,-300 --cam-look=0,0,-500
```

- `--cam-pos=x,y,z` with optional `--cam-look=x,y,z`: a fixed camera (it looks at the car
  without `--cam-look`).
- `--overview`: the whole lap from above, with the fog pushed back.
- `--time=day|dusk|night`: another time of day than the track's own, with stock lighting.
- `--scenery-dir=PATH`: read the scenery files from another folder; `--no-scenery`: ignore them.
- `--quality=low|medium|high`: the graphics preset.
- `--bench=N` (with `--frames=WARMUP` and Godot's `--disable-vsync`): prints the average frame
  time over N frames and quits.

`tests/fixtures/tracks/make_scenery_fixture.py` writes synthetic scenery for any lap into a
scratch folder, to try the runtime on a track whose real surroundings are not baked yet.

## Tests and tools

```bash
tests/run_tests.sh                 # all headless tests (about 5 minutes)
tests/run_tests.sh --filter=car    # only test files whose name contains "car"
tools/lap_demo.sh                  # autopilot drives two full laps of the Red Bull Ring, speeds per turn
tools/lap_check.sh monza           # autopilot lap check on any track: lap times, edge margin, impacts
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
  `Track` and the generic road, terrain and trackside builders, `Scenery` (buildings, trees,
  water, landmarks, floodlight masts) and `TrackEnvironment` (time of day and colours).
- `scripts/race/`: race manager (countdown, checkpoints, laps, splits, finish), autopilot, bots
  and the ghost recorder and player.
- `scripts/ui/`: HUD, race panel, standings, pause menu, results and loading screen.
- `assets/tracks/<id>/`: track data and generated meshes.
- `cad/`: build123d sources for the car, wheels, road and trackside profiles.
- `tests/`: `test_*.gd` files extend `TestCase` and run headless via `tests/runner.gd`.

## Data credits

Centreline © OpenStreetMap contributors (ODbL 1.0), relation 5309181. Elevation: EU-DEM v1.1
(Copernicus, © European Union) via OpenTopoData.

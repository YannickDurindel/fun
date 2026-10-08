# Fun Racer

A Trackmania-style racer for Linux, built with Godot 4.7.

## Quick start
```bash
tools/get_godot.sh                          # downloads Godot 4.7.2 (cached in ~/.cache/fun-racer)
tools/bin/godot --path .                    # race the Red Bull Ring (main scene)
tools/bin/godot --path . res://scenes/main.tscn   # free roam on the infinite plane
tests/run_tests.sh                          # headless tests
tools/screenshot.sh out.png                 # render a frame with autodrive
```

Controls: arrows / WASD to drive, Backspace or Enter to respawn, 1/2/3 to switch camera. Gamepads work too.

## Layout
- `scripts/car/car.gd`: the `Car` contract (speed, rpm, gear, inputs, `wheels: Array[WheelState]`) that every other system reads.
- `scenes/main.tscn`: the world, car, chase camera, HUD, audio and FX.
- `cad/`: build123d sources for the car. Generated `.glb` files go in `assets/car/`.
  Set up with `python3 -m venv .venv && .venv/bin/pip install -r cad/requirements.txt`.
- `tests/`: `test_*.gd` files extend `TestCase` and run headless via `tests/runner.gd`.
- `assets/tracks/red_bull_ring/track.json`: the Red Bull Ring centreline (4318 m), built by
  `tools/track/fetch_red_bull_ring.py` from OpenStreetMap (ODbL) and EU-DEM elevation.
  `scripts/track/track_data.gd` (`TrackData`) is the contract every track system reads.

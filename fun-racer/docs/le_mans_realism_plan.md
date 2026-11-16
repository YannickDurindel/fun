# Le Mans realism plan: survey-grade geometry and Real Racing 3-level visuals

Goal: Circuit de la Sarthe (`wec_le_mans`, 13 626 m) built from open French survey data
(about 10 cm geometry) and dressed to a hand-made, Real Racing 3-like look, running on the
project's target GPU (Intel HD 520, Godot **Mobile** renderer).

The work is split into **waves**. Inside a wave every workstream is one agent and they run in
parallel; a wave starts when the previous one is merged. Each workstream below lists what it
owns (files no other agent of the wave may edit), its inputs, outputs, acceptance tests and a
size estimate.

## Measurable targets (checked in wave 3)

| What | Today | Target |
|---|---|---|
| Elevation source | Terrain Tiles, 30 m, smoothed | IGN LiDAR HD ground points, 0.25 m road grid |
| Road surface | centreline height + flat 1.5 % crossfall | measured camber / crown every 2 m, 0.5 m lateral |
| Widths, kerbs, run-off | estimates (12 m Mulsanne, 9.5 m Arnage) | traced from 20 cm orthophotos, +/- 0.3 m |
| Elevation range | 37.3 m | the lidar's figure (no estimate) |
| Landmarks | OSM boxes | 10-15 modelled hero objects |
| Lighting | real-time sun + fog | baked lightmaps + sky, night variant with lit pits |
| Frame rate (HD 520, 1280x720) | measure in wave 1 | >= 50 fps on the pit straight with 10 cars |

## Two versions stay playable

The current build (`wec_le_mans`, generated from OpenStreetMap + global elevation) is kept as it
is. Everything this plan produces goes into a **separate track**, `wec_le_mans_survey`, with its own
recipe (`tools/track/tracks/wec_le_mans_survey.toml`, started as a copy of `wec_le_mans.toml`), its own
folder, records and ghosts. Until a race-options row "TRACK DATA: GENERATED / SURVEY" groups
them under one card (a small UI task for the last wave), the survey version is its own card in
the Endurance list. No agent of this plan edits `wec_le_mans.toml` or `assets/tracks/wec_le_mans/`.

## Shared rules for every agent

- Branch: work on the branch the session names; never commit, never switch branches.
- Never `git checkout/restore/stash/reset` anything except tracked `*.import` stub files your
  own `godot --import` modified outside the folders you own.
- Every Godot command: `flock <scratch>/godot.lock timeout 900 nice -n 5 <command>` (lap checks
  of Le Mans: `timeout 1500`). After a rebuild, run `godot --headless --path . --import` before
  any screenshot or lap check, or the game shows the stale road.
- `tools/lap_check.sh wec_le_mans` must print OK at the end of every workstream that changes
  geometry, in arcade AND `--handling=simulation`.
- **Licences.** IGN data (LiDAR HD, BD ORTHO, BD TOPO, RGE ALTI): Licence Ouverte 2.0, credit
  "IGN" in `track.json` / `terrain.json` attribution. OSM: ODbL, keep its attribution. Esri /
  Google imagery may be LOOKED AT for research but never shipped in an asset (their terms forbid
  it): textures come from IGN only.
- **Raw data stays out of git.** LiDAR HD tiles are 100-300 MB each: they go to a cache,
  `~/.cache/fun-racer/ign/` (downloaded once, reused by every agent). Only derived, compact
  products are committed to the track folder (grids, masks, small JPEGs), each < 20 MB, the
  whole track folder < 80 MB.

## Reference imagery (private use, never committed)

Real-world look comes from real references. For every 25 m of the lap there is a reference
index in `~/.cache/fun-racer/reference/<id>/index.json` (s -> frames / photos), built by the
reference agent from:
- YouTube onboard laps (4K, dry, daylight) and drone / track-walk videos of the hero spots,
  downloaded with yt-dlp for this private project only, frames extracted with ffmpeg and
  matched to s;
- Panoramax / Mapillary street-level photos of the public-road sections (Mulsanne, Arnage,
  Indianapolis), with their GPS and heading;
- Wikimedia Commons photos of the landmarks (Dunlop bridge, grandstands, pits, Tertre Rouge).
Raw videos, frames and photos stay in the cache; nothing from them is committed except
textures the projection experiment (W2-F) produces. Every W2 agent (landmarks, dressing,
landscape) must look at the references of its section before modelling anything, and the
validation wave compares game screenshots with reference frames at the same s.

## Wave 0 - data and quick win (1 agent, ~1 day)

**W0. Data acquisition + `ign` quick win.** Owns: `tools/track/lib/ign_data.py` (new),
`tools/track/tracks/wec_le_mans.toml` ([elevation] only), `tools/track/tests/test_ign_data.py`.
1. Switch Le Mans to the existing `[elevation] dataset = "ign"` (RGE ALTI 1-5 m, already
   supported, see README "Data sources"), rebuild, compare elevation range and grades with the
   terrarium build, lap check. This is a free improvement before the lidar work lands.
2. Downloader for the Géoplateforme open data, cached in `~/.cache/fun-racer/ign/`:
   - **LiDAR HD** classified point clouds (COPC .laz, 1 km tiles, Lambert-93 / EPSG:2154) for
     every tile within 600 m of the lap; list them in a manifest
     `assets/tracks/wec_le_mans/raw/ign_manifest.json` (tile ids, URLs, sizes, sha256).
   - **BD ORTHO** 20 cm (WMTS / WMS of the Géoplateforme, layer ORTHOIMAGERY.ORTHOPHOTOS.BDORTHO)
     over the same corridor; check whether the Sarthe has **PCRS 5 cm** and fetch it too if so.
   - **BD TOPO** buildings (footprints + heights) and road furniture for the corridor.
3. Install the readers in the venv (`laspy[lazrs]`, `pyproj`; add them to
   `cad/requirements.txt`), and a tiny smoke test reading one tile's ground class.
Accept: manifest complete (no gap along the lap), one tile read in the test, the `ign` build
passes lap check. Report total download size.

## Wave 1 - foundations (4 agents in parallel, ~2-3 weeks)

Interfaces fixed up front so the four can work at once:
- **Lidar grid file** (`lidar_road.bin` + `lidar_road.json`): float32 heights on a regular grid
  in the track frame (x east, z -north, metres from the finish line, y relative to it), cell
  0.25 m, covering everything within 40 m of the centreline; NaN where there is no ground
  point. A second, coarser `lidar_terrain.bin` (1 m) covers 600 m. JSON holds origin, cell,
  size, CRS transform, point density statistics.
- **Ortho products** (`ortho_edges.json`): per centreline sample (every 2 m) the left / right
  tarmac edge offset in metres (+ confidence), kerb segments `{s0, s1, side, kind: "red_white" |
  "flat" | "sausage", width}`, run-off polygons `{kind: "gravel" | "tarmac" | "grass", ring}`.

**W1-A. Lidar ground model.** Owns `tools/track/lib/lidar.py` (new), its tests, the
`lidar_hd` dataset entry in `tools/track/lib/net.py` / centreline / terrain hooks.
- Read COPC tiles (ground = class 2; also keep 9 water as ground level), reproject to the track
  frame, grid by robust per-cell median (reject outliers > 0.15 m from a local plane), fill
  small holes by inverse distance, leave big holes NaN and fall back to RGE ALTI there.
- New `[elevation] dataset = "lidar_hd"`: the centreline heights and the near terrain come from
  the grids; the far terrain stays on RGE ALTI.
- Accept: on the pit straight and Mulsanne the grid's residual against a 2 m local plane is
  < 3 cm RMS; the lap profile matches RGE ALTI within 0.5 m away from bridges / cuttings; the
  Dunlop hill and the Tertre Rouge descent visibly sharper; unit tests on a synthetic tile.
- Size: 1 week.

**W1-B. Road surface from measured cross-sections.** Owns `cad/track/road.py` (cross-section
code path only), `scripts/track/road.gd` (surface_point), `road_profile.json` schema
(additive: a per-station `xsec` array of lateral height offsets), tests.
- At every 2 m station sample the lidar grid across the road every 0.5 m, fit a robust
  smooth cross-section (camber, crown, drainage break), clamp physically implausible slopes,
  and build the road mesh from it instead of the analytic crossfall; banking logic stays for
  tracks without `xsec`.
- The game's `Road.surface_point()` and anything that assumes a planar section (autopilot
  lateral offsets, spawn, trackside) must read the measured section.
- Until W1-A lands, develop against a synthetic grid generated from today's Le Mans build.
- Accept: F1 tracks byte-identical; Le Mans road mesh follows the lidar within 2 cm at the
  sample points; no step at chunk joins; lap check OK in both handlings; screenshots of
  Tertre Rouge and Indianapolis show the real camber.
- Size: 1-1.5 weeks.

**W1-C. Edges, kerbs and run-off from orthophotos.** Owns `tools/track/lib/ortho.py` (new),
`tools/track/landmarks/` helpers it adds, tests, `ortho_edges.json`.
- Mosaic the BD ORTHO tiles along the lap, resample into road-aligned strips (s along, offset
  across, 5 cm/px), classify asphalt / grass / gravel / white paint / red-white kerb (HSV +
  texture rules, morphological cleanup; a small trained model only if rules fail), trace the
  two tarmac edges and kerbs per station, with a confidence; trees and shadows lower it.
- Write QA overlays: one PNG per 500 m with the traced edges drawn on the photo, saved in the
  scratchpad, and a summary of low-confidence stretches.
- Feed back: `[road]` width per station (from the edges), kerbs into the trackside layout
  table (`scripts/track/trackside_layouts/wec_le_mans.gd`, new), run-off kinds into landcover.
- Accept: widths within 0.3 m of manual measurements at 20 spot checks (agent measures them
  on the photo by hand); every kerb of the official map found; QA overlays reviewed.
- Size: 1.5 weeks.

**W1-D. Visual foundations: materials and lighting.** Owns `assets/tracks/_shared/` materials
it adds (new files only), road / kerb / grass shaders under a per-track opt-in
(`environment.json` flag `"look": "detailed"`), `scripts/track/track_environment.gd` additions,
a perf benchmark script.
- Asphalt: tiling detail + macro variation, repair patches, joins, a darker rubbered racing
  line from `road_profile.json` `racing_line`, wetness-ready roughness. Kerbs: real 3D profile
  (raised, sawtooth, sausage) as mesh, not just paint. Grass, gravel and tarmac run-off detail
  textures with distance blending. Painted lines with wear.
- Lighting: `LightmapGI` bake for static scenery (Mobile renderer supports it), sky and
  tonemapping tuned (AgX / ACES), reflection probes on the pit straight, light fog.
- Night variant for Le Mans: pit lane and grandstand lights (emissive + a few omni lights),
  car headlights (the endurance body already has a `Headlight` material).
- Perf: `tools/bench` run on the pit straight with 10 bots at 1280x720; budget >= 50 fps on
  HD 520 (measure the current baseline first; if this machine is not an HD 520, report the
  ratio and keep the draw-call / texture budget conservative).
- Accept: opt-in only, F1 tracks unchanged; before / after screenshots at 6 spots; bench.
- Size: 2 weeks.

## Wave 2 - Le Mans assembly and dressing (4 agents in parallel, ~2-3 weeks)

**W2-E. Integration.** Owns `tools/track/tracks/wec_le_mans.toml`. Switch to `lidar_hd`,
measured sections and ortho widths; turn table and finish line re-checked on the new geometry;
rebuild; lap check both handlings; compare with the wave-0 build (report elevation, widths,
lap time deltas).

**W2-F. Hero landmarks.** Owns `tools/track/landmarks/wec_le_mans.py` (new, same pattern as
`spa.py`). Modelled from the orthophoto + lidar building heights + reference photos:
1. Pit building, race control and the main grandstands of the pit straight
2. Dunlop bridge (the tyre arch) and the Dunlop curve grandstands
3. The Esses and Tertre Rouge (bridge, grandstand, the bend's walls)
4. The two Hunaudières (Mulsanne) bridges and the chicane grandstands
5. Mulsanne corner: the junction buildings and roundabout furniture
6. Indianapolis and Arnage: the restaurant / buildings, bend grandstands
7. Porsche curves: walls, banks
8. Ford chicanes and the Raccordement grandstands
Each with an `s` anchor, simple materials from W1-D's library, LOD (one simplified mesh beyond
300 m). Accept: screenshot of each next to a reference photo description; perf budget holds.

**W2-G. Trackside dressing.** Owns `scripts/track/trackside_layouts/wec_le_mans.gd` (after
W1-C's kerbs), billboard / marshal-post / fence assets it adds.
- Barriers by section (armco on public roads, concrete + catch fences in the Bugatti part,
  tyre walls in run-offs) from OSM `barrier=*`, the orthophoto and the lidar (fences show as
  thin vertical point lines).
- Marshal posts at their real places (they are visible on the photos), fictional-brand
  billboards, the public-road furniture of the Mulsanne (lamp posts, signs, kerbstones).
- Trees from the lidar vegetation classes (3-5): real positions and heights, as instanced
  trees (replaces the random forest fill near the road).

**W2-H. Far landscape.** Owns terrain texture generation for Le Mans. Drape a downsampled BD
ORTHO (2-5 m/px) over the near and far terrain, blended with the landcover materials up
close; BD TOPO / lidar class 6 buildings with real heights for the town of Le Mans and the
villages along the lap.

## Wave 3 - validation and polish (2 agents, ~1 week)

**W3-I. Validation.** Lap times vs real (Hypercar pole about 3:22-3:25 with the endurance car
model; report the gap per sector), elevation profile vs published figures, widths vs the 20
spot checks, a 24-stop screenshot tour reviewed, the full Godot suite and the pipeline tests.
**W3-J. Perf and polish.** Fix what the tour and bench find; final night pass; README section
"Survey-grade tracks (lidar + orthophotos)" so the method extends to the Nürburgring (Rhineland-
Palatinate open lidar), Fuji (Virtual Shizuoka point clouds) and the US tracks (USGS 3DEP).

## Order of launch

```
W0  ->  W1-A, W1-B, W1-C, W1-D  ->  W2-E, W2-F, W2-G, W2-H  ->  W3-I, W3-J
```
W1-D does not depend on any data and may start together with W0.

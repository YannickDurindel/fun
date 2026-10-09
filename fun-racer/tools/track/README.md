# Track build pipeline

One command builds everything the game needs for a circuit from open data: the centreline
scaled to the official lap length, elevation, turns and sectors, the road mesh, the terrain
and the menu entry.

```sh
# once
python3 -m venv .venv && .venv/bin/pip install -r cad/requirements.txt

# a circuit of assets/tracks/calendar.json: the id gives name, length and turn count
.venv/bin/python tools/track/build_track.py imola --osm-relation 9291096 --plot

# rebuild a track that has a recipe, without touching the network
.venv/bin/python tools/track/build_track.py red_bull_ring --offline
```

All commands run from `fun-racer/`.

## How to add a track

### 1. Find the circuit in OpenStreetMap

The best source is a relation tagged `type=circuit`: it lists the ways of one layout, often
with the pit lane marked by a member role and the start / finish line as node members.

- Search on <https://www.openstreetmap.org> for the circuit, click a piece of the racing
  surface (a way tagged `highway=raceway`), and look under "Part of" for a relation such as
  *Relation: Autodromo Internazionale Enzo e Dino Ferrari (9291096)*. The number is the id.
- No relation? Use a bounding box instead (`--osm-bbox west,south,east,north`, in degrees):
  every `highway=raceway` way inside it becomes a candidate. Nominatim gives a box quickly:
  `https://nominatim.openstreetmap.org/search?q=Hungaroring&format=jsonv2` (its
  `boundingbox` is south, north, west, east; add a small margin).
- Several relations for one venue (Barcelona has "with chicane" and "without chicane")?
  Pick the one of the current Grand Prix layout.

Overpass is not needed; the pipeline only uses the main OSM API
(`/api/0.6/relation/<id>/full`, `/way/<id>/full`, `/map?bbox=`).

### 2. Write the recipe (optional at first)

For a circuit in `assets/tracks/calendar.json` nothing has to be written down: the first
build can run from the command line. Once it works, put the choices in
`tools/track/tracks/<id>.toml` so the build can be repeated:

```toml
id = "imola"                 # must match the file name; name, country, official length and
                             # turn count come from calendar.json unless given here
# name = "..."  grand_prix = "..."  country = "..."  country_code = "IT"  city = "..."
# length_m = 4909            # official lap length (the plan view is scaled to it)
# turns = 19                 # official turn count (steers which kinks get a number)

[osm]
relation = 9291096
# ways = [1, 2, 3]           # manual fallback: the loop's way ids in driving order
# bbox = [w, s, e, n]        # or: all raceway ways in a box
# exclude_ways = [123]       # ways of other layouts the search must not use
# extra_ways = [456]         # ways the relation / box lacks (a gap in the data); only the
                             # piece between the nodes shared with the other ways is used
# avoid_nodes = [789]        # nodes the lap must not pass: picks one of two loops that
                             # differ only by the way they take through a junction
# avoid_names = ["short"]    # penalise ways whose name contains one of these
# ignore_oneway = true       # street circuits: oneway tags follow traffic, not the race
# length_tolerance = 0.03    # how far the OSM loop may be from the official length
# [[osm.round]]              # a lap on public roads turns at a junction on one sharp vertex:
# node = 159355126           #   replace the loop +/- reach_m around it by a rounded corner
# reach_m = 60.0             #   (minimum radius about reach_m * cos^2(a/2) / sin(a/2))
# to_node = 159355127        #   optional: a two-vertex dogleg (a carriageway crossover)
#                            #   from node to to_node becomes an S-bend

[layout]
# direction = "anticlockwise"   # only needed when OSM has no (or wrong) oneway tags
# finish = [44.3439, 11.7167]   # lat, lon of the finish line
# start = [44.3441, 11.7140]    # lat, lon of the start line (grid); or:
# start_offset_m = 0            # start line this far after the finish line
# sectors = [1650.0, 3300.0]    # where sectors 2 and 3 begin, metres from the finish line
# spline = "centripetal"        # "uniform" only for the Red Bull Ring (its original build)
# [[layout.shift]]              # move a stretch of the centreline sideways (see Size)
# s = [1200.0, 1500.0]          #   from, to (may wrap around the finish line)
# lateral_m = 2.5               #   metres, + = to the right in race direction
# blend = 60.0                  #   metres over which it fades in and out (default 60)

[elevation]
# dataset = "srtm30m"        # default: chosen by coverage (see Data sources)
# smooth_sigma_m = 45.0
# key_join_m = 250.0         # [[elevation.key]] entries closer than this follow one curve
[[elevation.smooth]]          # another smoothing on one stretch (keep a crest sharp)
s = [900.0, 1250.0]           # from, to (may wrap around the finish line)
sigma_m = 15.0                # Gaussian sigma there, metres (0 = the DEM samples as they are)
blend = 40.0                  # metres over which it fades back to smooth_sigma_m (default 40)
[[elevation.override]]        # correct the DEM profile on a stretch (bridges, crossovers)
s = [4690.0, 4990.0]          # from, to (may wrap around the finish line)
straighten = true             # straight line between the heights at the two ends, and / or
offset = 0.8                  # metres added inside the stretch, fading out over ...
blend = 120.0                 # ... this many metres on both sides (default 60)
[[elevation.key]]             # pin the height at one distance (see Size)
s = 1170.0                    # metres from the finish line
y = -1.0                      # metres above the finish line; or abs = 416.8 (above sea level)
blend = 60.0                  # fade-out on a side without a neighbouring key (default 60)
# join = true                 # one curve from the previous key to this one, however far
note = "top of Raidillon"

# Either names for the automatically detected turns ...
[[turn]]
id = "T7"
name = "Tosa"
# ... or the whole table pinned: every entry with direction and `s`. The apex is then the
# curvature peak within 12 m of `s`, and automatic detection is only reported, not used.

[road]
# base_width = 13.0   grid_width = 15.0   crossfall = 0.015   camber_gain = 2.5
# bank_keys = [[0.0, -0.015, "grid"], ...]     # full tables replace the defaults
# retaining_walls = true      # hillside circuits: a wall under each verge edge that has a
                              # lower stretch of the lap beside it (see Known limits)
# width_keys = [[0.0, 15.0, "grid"], ...]
# track_json_widths = false  # keep a nominal width in track.json: see "Road widths"
[[road.override]]             # or change single stretches
s = [2700.0, 2950.0]          # from, to (may wrap around the finish line)
width = 12.0                  # 6 to 30 m
bank = -0.02                  # radians, + = left edge higher; limit +/- 0.03
blend = 40.0
[[road.pair]]                 # two stretches that are the two carriageways of one road
a = [2175.0, 2530.0]          # from, to of the first (it builds the wall between them)
b = [4725.0, 5085.0]          # from, to of the second
separation = 14.0             # optional: push the two centrelines this far apart
gap = 2.0                     # least room between the tarmac edges, for the wall (default 1.5)
blend = 40.0                  # metres over which the push fades in and out (default 60)

[terrain]
# near = [x0, x1, z0, z1]     # game metres, multiples of 200; default: track box + 450 m
# far = [x0, x1, z0, z1]      # default: a 12 km square around it
# smooth_sigma_m = 150.0      # flat sites: blur the DEM so its noise does not become hills
```

Unknown keys are an error, so typos do not go unnoticed. The Red Bull Ring recipe
(`tracks/red_bull_ring.toml`) is a complete example with pinned turns and a full
cross-section table.

### 3. Run the build

```sh
.venv/bin/python tools/track/build_track.py <id> [--recipe FILE] [--offline] [--out DIR]
    [--steps centreline,road,terrain,info] [--plot [FILE]] [--compare DIR]
    [--osm-relation N | --osm-bbox w,s,e,n] [--name ...] [--length M] [--turns N]
    [--direction clockwise|anticlockwise] [--cache DIR]
.venv/bin/python tools/track/build_track.py <id> --report | --report-json [--out DIR]
```

| Step | Needs | Writes |
|---|---|---|
| `centreline` | OSM, DEM (about 25 requests) | `track.json`, `build_info.json` |
| `road` | numpy (the venv) | `road_mesh.glb`, `road_profile.json`, textures, materials, `road_mesh.glb.import`, `trackside_profiles.json` |
| `terrain` | DEM (150-450 requests, 1 per second) | `terrain.json`, `terrain_height.bin`, `terrain_dist.bin`, `terrain_far.bin` |
| `info` | - | `track_info.json`; `scenes/tracks/<id>.tscn` if it does not exist |

- Output goes to `assets/tracks/<id>/`. With `--out DIR` everything, including the scene
  file, goes to `DIR` instead and the game is not touched: use it to try a circuit out.
- Every download is cached in `<track folder>/raw/`. Commit that folder with the track:
  `--offline` then rebuilds it exactly, and the tests run on it.
- A full build takes 3 to 8 minutes, nearly all of it waiting for the DEM rate limit. An
  offline rebuild takes about 20 seconds.
- OpenTopoData's public API allows 1000 requests per day, so two or three new tracks a day.
  If a build stops on the limit, run it again later: finished requests are cached.
- `track_info.json` gets `"available": true` once road and terrain exist; the menu then
  lists the track instead of showing it as "coming soon".
- `build_info.json` is the build's log: the loop that was chosen and the runners-up, where
  the start / finish line came from, the DEM dataset, the automatic turn candidates with
  their angles, and every warning.

### 4. Check the plot

`--plot` writes `plot.png` (needs `.venv/bin/pip install matplotlib`; without it an SVG with
the same content is written): the centreline coloured by
height, turn numbers, finish and start lines, sector boundaries, an arrow for the driving
direction. Compare it with the official circuit map:

- Is it the right layout (chicanes, no pit lane, no motorcycle variant)?
- Does the arrow point the right way, and is the finish line on the pit straight?
- Do the turn numbers match the official map?
- Is the elevation range close to the published figure, and are the high and low points
  where they should be?

Also read the build's `WARNING:` lines; each one says what to put in the recipe.

### 5. When the automatic result is wrong

| Symptom | Fix |
|---|---|
| "do not form a closed loop" | The ways have a gap; the message lists dead ends and the nearest other dead end. Fix OSM, or list the loop by hand with `[osm] ways`. |
| "no loop ... matches the official lap length" | Wrong layout or wrong official length. The message lists the closest loops and every candidate way with its length. Use `exclude_ways`, or raise `length_tolerance` if OSM is simply drawn long or short. |
| "the layout is ambiguous" | Two loops fit equally well (a chicane variant, usually). Drop the wrong one's ways with `exclude_ways`. |
| The lap uses a motorcycle chicane or a short cut | Ways named like alternative layouts (MotoGP, kart, long lap, club, ...) are penalised automatically; add your own words with `avoid_names`, or `exclude_ways`. |
| The lap runs backwards | `[layout] direction`. |
| Finish line in the middle of the longest straight, with a warning | OSM has no start / finish data: set `[layout] finish = [lat, lon]` (right-click the line on openstreetmap.org, "Show address"). |
| Wrong number of turns, or numbers shifted | Look at `turns.auto_candidates` in `build_info.json`. Usually a flat-out kink is counted or missed: pin the table with `[[turn]]` entries (`id`, `name`, `direction`, `s`). |
| A corner looks polygonal or has a far too small radius | OSM has too few nodes there. Improve OSM, or accept it: the road is only as good as the centreline. |
| Road too narrow / wide, wrong camber | `[road]` keys or `[[road.override]]` (see Size). |
| A hill too flat, too steep or in the wrong place | `[[elevation.key]]`, `[[elevation.smooth]]` (see Size). |
| Two stretches of the lap squeezed against each other | `[[road.pair]]` with a `separation` (see Size). |
| "OSM tags the road as N m wide" | A hint from the map's `width` tags. Check the real width; set it in `[road]` if the tag is right. |
| The autopilot keeps to the middle of a wide road, or leaves a narrow one | `track.json` has a nominal width: remove `[road] track_json_widths = false` (see Road widths). |
| "the mesh could not be built" | The centreline folds on itself (see Known limits). |
| "the lap crosses itself ... only N m apart in height" | A figure of eight: the DEM gives both roads the same height. Separate them by at least 5.5 m with `[[elevation.override]]` entries (see Crossovers). |
| DEM voids, flat sea, steps in the terrain | Try another `[elevation] dataset`. |
| Rolling hills around a circuit on a plain | That is DEM noise (a few metres): set `[terrain] smooth_sigma_m` (100 to 200), and raise `[elevation] smooth_sigma_m` for the road. |

## How it works

**Loop extraction** (`lib/osm.py`). The candidate ways (relation members without a pit /
penalty / joker role, or all raceway ways of a box) are split at the nodes they share, which
gives a small directed graph: `oneway=yes` ways can only be driven in their drawing
direction. Every simple cycle of that graph is a possible lap. Each is scored by its
relative distance from the official length, plus a penalty for the share of the lap on ways
named like a pit lane and a flat penalty for ways named like another layout. The best one
wins if it is within `length_tolerance` and no different loop scores within 0.3 % of it;
otherwise the build stops and lists the candidates. Length alone is not enough: on the Red
Bull Ring the MotoGP chicane layout (4317 m in OSM) is closer to the official 4318 m than
the Grand Prix loop is (4305 m), and only the chicane's name rules it out.

**Start / finish**: recipe, else relation members with the role `start` / `finish`, else
nodes tagged `raceway=start` / `raceway=finish` on the loop, else the middle of the longest
straight (with a warning). Without a separate start line the grid starts at the finish line.

**Centreline** (`lib/centreline.py`). Local metres about the finish line, Catmull-Rom
resampling every 2 m, a 4 m Gaussian in plan view, uniform scaling to the official length.
Elevation is sampled every 10 m at the unscaled positions and smoothed with a 45 m Gaussian.
Frame: x = east, y = up relative to the finish line, z = -north.

**Turn detection** (`lib/turns.py`). The smoothed curvature is cut into lobes of one sign
above 1/667 m; a lobe is split where two real corners are joined by a gentle bend;
neighbouring same-direction kinks are merged; a lobe turning at least 15 degrees is a corner
and at least 4 degrees a kink. All corners count, and kinks are added, biggest first, until
the official count is reached. That last step is a heuristic: official numbering counts some
flat-out kinks and not others, and nothing in the geometry says which.

- Imola, no recipe: 19 turns found, 19 official, in the official order.
- Red Bull Ring: 10 turns found, 10 official. Seven are the corners of the table the game
  shipped with, exactly. The other three differ: the detector numbers the left kink on the
  climb (T2), and the long right-handers after Schlossgold (T5) and after Wuerth (T8), as
  the circuit's official map does, while the shipped table instead has a 5 degree kink at
  s = 749, the first curvature peak of the Rauch left-hander, and a 12 degree kink after
  Red Bull Mobile. The recipe pins the shipped table, so the game is unchanged.

**Sectors**: 1/3 and 2/3 of the lap, moved to the nearest point on a straight.

**Road** (`cad/track/road.py`, `cad/track/banking.py`). Width 13 m, 15 m around the grid;
1.5 % crossfall on straights leaning towards the nearest corner; camber proportional to
curvature, capped at 0.03 rad; the grid drains left. 30 m grass verges, clipped where they
would fold. The start / finish lines and grid boxes are painted by the tarmac shader from
the lap length and `start_s`, so they need nothing per track.

**Road widths.** The road step builds the widths of the `[road]` table and writes them to
`road_profile.json`. The game's drivers (the autopilot's racing line, the bots' off-road test)
read the `width` of `track.json` instead, so the two must agree: on a road widened to 18 m the
drivers would otherwise keep to the middle 13 m, and on one narrowed to 9 m they would plan a
line through the wall. The rule:

- A recipe that states a width anywhere (`base_width`, `grid_width`, `width_keys`, or a
  `[[road.override]]` with a `width`) gets the built widths in `track.json` (which needs
  numpy in the centreline step, like the road step).
- A recipe that states none gets a nominal 13 m at every point. The road step's own default is
  13 m with a 15 m grid, so the grid is wider than the drivers think; that is how the tracks
  were first built, and they stay byte for byte the same until their widths are set.
- `[road] track_json_widths = false` keeps the nominal value (13 m, or `base_width` when that
  is less) on a recipe that does state widths. Red Bull Ring and Monaco carry it, because they
  were built before this rule; remove the line when their widths are corrected.
  `track_json_widths = true` forces the built widths.

The road step stops if `track.json` no longer agrees with the `[road]` table, which happens
when the table is edited and only the road is rebuilt: run the centreline step again.
Widths from 7 to 22 m and width changes rolled in over 15 m are driven cleanly by the autopilot
in both handling modes; the recipe accepts 6 to 30 m.

**Width tags** (`lib/osm.py`, `lib/centreline.py`). Where the loop's OSM ways carry a `width`
tag (Zandvoort on all of them, single ways at Gilles Villeneuve and the Hungaroring), the
centreline step records them as stretches of the lap in `build_info.json` (`osm.width_tags`:
`s` range, `width`, `ways`) and warns when the road the recipe builds is more than 1.5 m off
all along a stretch. They are never applied: a mapper's figure may be kerb to kerb or wall to
wall, and one number covers a whole way.

**Height keys** (`lib/centreline.py`). The DEM profile is smoothed with a 45 m Gaussian, which
takes out the noise and with it every short steep ramp (Spa's Raidillon comes out at 12.8 %
against about 17 % in reality), and a surface model adds what is not road (trees, buildings,
the far bank of a cutting). `[[elevation.key]]` pins the road to a known height at a distance:
`y` metres above the finish line, or `abs` metres above sea level.

- Keys closer together than `[elevation] key_join_m` (250 m), or joined by hand with
  `join = true` on the later one, replace the profile between them by a monotone cubic through
  the keys: two keys declare a ramp, a key on a crest is the highest point, and nothing
  overshoots. The slope at a key between two others follows from its neighbours (zero at a
  crest or a dip); at the first and last key of a run it is the slope of the profile outside.
- A key without a joined neighbour on one side adds its correction to the DEM profile there,
  fading out over `blend`, so the detail of the DEM survives. A blend never reaches the next
  key, so every key is met exactly.
- Keys are applied after `[[elevation.override]]` and the 10 m smoothing that follows the
  overrides, and nothing smooths the profile after them: a ramp is as steep as it was declared.
- `y` is relative to the finish line as it ends up. A key next to the line moves the line (and
  `origin_elevation_m`) with it and the other keys still come out as written; a key at s = 0
  can only say `y = 0` or an `abs`. Keys with `y` joined across the line need one at s = 0.

`[[elevation.smooth]]` is the lighter tool: on its stretch the DEM is smoothed with its own
`sigma_m` instead of the lap's, which keeps a real crest or compression that the lap-wide
smoothing rounds off, without letting the noise of the whole lap back in. What it changes is
added after the overrides (so their 10 m smoothing does not blur it again) and before the keys.

**Side-by-side roads** (`lib/layout.py`, `cad/track/road.py`, `scripts/track/trackside.gd`).
OSM draws a road as one line near its middle, good to a few metres. That is not enough where
two stretches of the lap are the two carriageways of one road: in Baku the Turn 6 to Turn 7
road and the main straight are drawn 9.5 to 11.7 m apart, which once forced both down to 8 m.
`[[road.pair]]` names the two stretches (`a`, `b`):

- With `separation`, the centreline step pushes both away from each other, by the same amount,
  until the centrelines are that far apart (never closer together), before the lap is scaled to
  its official length. Give each road its real width with `[[road.override]]`; the separation
  is half of each width plus the median. `[[layout.shift]]` moves a single stretch by a fixed
  amount instead (a road drawn on the wrong side of a wide street). Either moves the points
  the elevation is sampled at: with a tile dataset (`terrarium`) the cached tiles still serve
  them, with an OpenTopoData dataset the centreline step needs the network again (about 25
  requests) before `--offline` works. A stretch that includes the finish line takes the line,
  and the origin of the frame, along with it.
- The road step checks that `gap` metres are left between the two tarmac edges all along (the
  build stops and says how far apart the centrelines must be), so the two ribbons can never
  overlap, and ends both verges on the line half way between the edges: one continuous median.
- The pair goes to `road_profile.json` (`pairs`, with the side each stretch has the other on
  and the measured gap and separation). The runtime trackside builds one wall on the middle of
  the median, drawn by stretch `a`, instead of one wall per road.

The wall keeps the cars apart, and the drivers follow the lap with a position hint
(`TrackData.closest_s(pos, hint)`), so the nearer centreline of the other carriageway does not
confuse them; without a hint `closest_s` may answer with either stretch there.

**Size report.** `build_track.py <id> --report` builds nothing and prints, from the files of
the track folder (or of `--out DIR`): one row per turn and per straight with its s range,
minimum radius, width, bank and gradient ranges and the height at entry, apex and exit; the
lap's length, elevation range, total climb and steepest gradients with their positions; the
OSM width tags, pairs, crossovers and the build's warnings. `--report-json` prints the same as
JSON. Heights are metres above the finish line, gradients and bank per cent.

### How to correct a track's size

1. `build_track.py <id> --report > before.txt`. Put the reference figures beside it: official
   length and turn count (already enforced), track width (FIA circuit documents, the circuit's
   own data sheet), elevation range and the gradients that are quoted for it, the heights of
   its named points. Write the source of every figure into the recipe as a comment, and mark
   estimates as estimates.
2. Widths: `[road] base_width` and `grid_width`, then `width_keys` or `[[road.override]]` for
   the stretches that differ (a wide braking zone, a narrow chicane). Read the
   `OSM width tag` lines of the report as a hint. If the recipe has
   `track_json_widths = false`, remove it.
3. Heights: compare `y in / y apex / y out` and `grade %` with the reference, turn by turn.
   A hill that is right in height but too soft: `[[elevation.smooth]]` with a small `sigma_m`
   on it. A height that is wrong: `[[elevation.key]]` at the points you know (foot, crest,
   apex), two or more keys for a ramp. A spurious step (a bridge, trees): keys either side of
   it with `join = true`, or `[[elevation.override]] straighten`.
4. Two stretches side by side that had to be narrowed: `[[road.pair]]` with the real
   `separation`, and the real widths.
5. Rebuild all steps offline (`--offline`), `--report > after.txt`, and compare. Then
   `tools/bin/godot --headless --path . --import`, `tools/lap_check.sh <id>` and
   `--handling=simulation` (both must say `OK`), and the track's Godot test
   (`tests/run_tests.sh --filter=track_<id>`), whose bands follow the new figures.

**Crossovers** (`lib/centreline.py`, `cad/track/bridge.py`). A lap that crosses itself in
plan view (Suzuka) needs no hand-written way list: the bridge way shares no node with the road
under it, so the loop search sees one simple loop. The centreline step finds the crossing,
records it in `track.json` (`crossings`: `s_lower`, `s_upper`, `clearance`) and stops unless
the two roads are at least 5.5 m apart there; the DEM never gives that, so the recipe sets the
heights with `[[elevation.override]]` (`straighten` removes the hump and the dip the DEM shows
at a bridge, `offset` lifts the deck). The road step then builds the bridge: the upper road
loses its verges where the ground belongs to the lower road and is carried by a concrete
deck, with side walls down to the ground and an underpass for the lower road; the lower road
ends its verges before the deck. The terrain keeps the ground of the lower road, pressed
under it as far as its verge plus a mesh cell, and with a 10 m mesh that cutting is some
70 m wide: the deck spans all of it, so it is far longer than the real bridge (Suzuka: 126 m
against about 35 m) and looks like an embankment between retaining walls. The stretches go
to `road_profile.json` (`bridges`); the runtime trackside puts a parapet with a fence on the
deck and keeps the lower road's barriers inside the underpass. Tracks without a crossing get
no extra keys and build exactly as before.

**Terrain** (`lib/terrain.py`). A 20 m DEM grid over the centreline's bounding box plus
450 m (snapped to 200 m), meshed at 10 m and pressed 0.3 m under the road and verges inside
the track corridor; a 200 m grid over a 12 km square for the horizon.

**Scene and materials.** For a new track the pipeline copies the reference track's shaders
and materials (`assets/tracks/red_bull_ring/road_*.gdshader`, `road_*.tres`) with the paths
replaced, writes the `.import` settings that bind them to the mesh, and generates a minimal
`scenes/tracks/<id>.tscn`: a `Track` root (`track_id`, `track_json`) with `Road`,
`Trackside`, `Terrain` and `Race` children. The template is in `lib/info.py`. It is kept
deliberately small because the runtime side is being made generic at the same time: if
tracks become one scene driven by the track id, the template (or the scene file) can go.
Until then `scripts/track/road.gd` and `trackside.gd` still load some files from the Red
Bull Ring folder, so a new track is not playable from this pipeline alone.

## Files

```
tools/track/build_track.py      the command
tools/track/lib/                recipe, osm, centreline, layout, turns, terrain, info, report, plot,
                                compare, net, geom
tools/track/tracks/<id>.toml    recipes
tools/track/tests/              offline tests
tools/track/fetch_*.py          old entry points, now thin wrappers
cad/track/road.py, banking.py   road mesh and cross-section
cad/track/bridge.py             the bridge of a lap that crosses itself
cad/track/trackside_profiles.py kerb / barrier profiles (track-independent)
```

## Tests

```sh
.venv/bin/python -m unittest discover tools/track/tests
```

Offline, about 40 seconds. `test_rebuild_rbr.py` rebuilds the Red Bull Ring into a temporary
folder and compares it with the committed assets: positions within 1 cm, identical turn and
sector tables. The same check from the command line:

```sh
.venv/bin/python tools/track/build_track.py red_bull_ring --offline --out /tmp/rbr_rebuild \
    --compare assets/tracks/red_bull_ring
```

## Data sources and licences

| Data | Source | Licence / credit |
|---|---|---|
| Centreline, names, start / finish | OpenStreetMap, via the OSM API | (c) OpenStreetMap contributors, Open Database License (ODbL) 1.0. The attribution must stay visible to players: it is written to `track.json` (`attribution`). The derived centreline is a "produced work / derivative database" under ODbL: keep the attribution and share fixes back to OSM. |
| Elevation, Europe | EU-DEM v1.1, 25 m (`eudem25m`) | Copernicus Land Monitoring Service, (c) European Union. Free use with the credit "produced using Copernicus data and information funded by the European Union - EU-DEM layers". |
| Elevation, 56 S to 60 N | SRTM GL1, 30 m (`srtm30m`) | NASA / USGS, public domain; credit NASA SRTM. |
| Elevation, elsewhere | ASTER GDEM v3, 30 m (`aster30m`) | NASA / METI, free use; credit "ASTER GDEM is a product of METI and NASA". |
| DEM access | [OpenTopoData](https://www.opentopodata.org) public API | Free service: at most 100 locations per request, 1 request per second, 1000 requests per day. |

`ign` is for circuits in France and Monaco: IGN's RGE ALTI terrain model (ground level, 1 to
5 m), read from the Geoplateforme altimetry service, 2000 points per request and no quota
(Monaco: 9 requests). In a city it is the difference between a street profile and a rooftop
profile: Monaco comes out with a 41.8 m elevation range (42 m published) and a start line
3.7 m above the sea, where Terrain Tiles give 50.8 m and put Sainte Devote 20 m above the
start line. The open sea has no data and is taken as sea level. Tunnels are not in a terrain
model either: straighten them with `[[elevation.override]]`. Credit: IGN, RGE ALTI, Licence
Ouverte 2.0.

`terrarium` is a fourth choice that does not go through OpenTopoData: Terrain Tiles on AWS
Open Data (Mapzen's global mosaic of SRTM, EU-DEM, 3DEP and others, as PNG tiles at zoom 13).
It has no daily quota and a circuit needs only a handful of tiles, so use it when building
several tracks in a day: `[elevation] dataset = "terrarium"`. Credit: Mapzen Terrain Tiles
and its sources (see https://github.com/tilezen/joerd/blob/master/docs/attribution.md).

`ahn` is for circuits in the Netherlands: the national lidar terrain model (AHN, ground
level, 0.5 m), read from PDOK's WCS as averaged GeoTIFF tiles (about 9 x 11 m pixels for the
centreline and the near terrain, ten times that for the horizon; six tiles for Zandvoort, no
quota). The 25-30 m global sets flatten dunes: Zandvoort comes out with a 4.7 m elevation
range from Terrain Tiles and 8.4 m from AHN. Water and buildings are voids, filled like any
other. Credit: Actueel Hoogtebestand Nederland, via PDOK.

Without that setting the dataset is chosen by coverage: EU-DEM inside its box (latitude 34 to 72, longitude -25
to 45), otherwise SRTM, otherwise ASTER. If EU-DEM answers with voids for more than a fifth
of the centreline (it only covers the EEA countries) the build falls back to the next one.
The choice is recorded in `build_info.json` (`dem_dataset`) and in the attribution strings
of `track.json` and `terrain.json`. The terrain uses the same dataset as the centreline.

## Known limits

- **Widths and camber are estimates.** OSM rarely has widths for circuits, and nobody
  publishes per-corner camber. Defaults follow the FIA Grade 1 rules; correct them in the
  recipe when you know better.
- **No real banking.** Bank is capped at 0.03 rad (1.7 degrees) because the terrain sits
  only 0.3 m under the road centre. Zandvoort's 18 degree corners or an oval cannot be
  represented yet.
- **DEM resolution.** 25-30 m cells, smoothed over 45 m along the lap: crests and
  compressions shorter than about 100 m are flattened, and cuttings, embankments and
  earthworks narrower than a cell are missing or smeared. EU-DEM and SRTM are surface
  models, so buildings and trees leak into the height; elevation ranges come out within a
  few metres of published figures (Imola: 33 m built, about 30 m published).
- **Street circuits.** Buildings dominate the DEM in a city; expect a bumpy, wrong profile
  and raise `smooth_sigma_m`. The racing line through a city is often not mapped as
  `highway=raceway`, `oneway` tags follow traffic (`ignore_oneway`), and dual carriageways
  are two ways: these need a relation or a hand-written way list.
- **Bridges and tunnels.** The DEM has one height per point, so a bridge gets the valley
  floor (or a smeared mix) and a tunnel gets the hilltop. `[[elevation.override]]` corrects
  the road's height, but only a road that crosses the lap itself gets a deck: a bridge over
  a river or a public road still stands on a terrain embankment, and there are no tunnels.
- **Crossovers** are built (see How it works), with a deck much longer than the real bridge
  and plain walls instead of the real abutments. Two crossings closer than 140 m along
  either road, or roads that stay on top of each other for longer than that, stop the build.
- **Terraces.** Where two stretches of the lap run side by side at different heights, the
  terrain between them follows the lower one and the upper verge would hang in the air.
  `[road] retaining_walls = true` closes that with plain concrete walls (Monaco: up to 33 m
  high under Beau Rivage, where the real slope is covered in buildings). Without it such a
  circuit shows the underside of its verges.
- **Sea and lakes** have no data in some datasets; voids are filled from the nearest valid
  point in the same grid row, which is fine for a horizon but not for a harbour chicane.
- **Sparse OSM geometry.** A corner drawn with four nodes becomes a slightly polygonal
  corner; the 4 m smoothing hides most of it, at the cost of rounding real chicanes a little.
- **The plan view is scaled** to the official length, normally by well under 1 %. A warning
  appears above 2 %, which usually means the wrong layout.
- **Kerbs, barriers, buildings** are not built here; the runtime lays them out.

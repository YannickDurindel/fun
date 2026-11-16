# Nordschleife realism plan: survey-grade geometry and dressing for the Green Hell

Track: `n24_nurburgring` (Nürburgring 24h layout: GP-Strecke + Nordschleife, 25 378 m,
clockwise). Same method as `docs/le_mans_realism_plan.md` (read it first: its **shared rules**,
**licences**, **raw data stays out of git** and the two **interface files** — the lidar grid
and `ortho_edges.json` — apply here unchanged). This file lists what is different.

Why this track first for geometry: what makes the Nordschleife is exactly what 30 m smoothed
elevation data removes — the crests and jumps (Flugplatz, Pflanzgarten, Brünnchen), the
compressions (Fuchsröhre), off-camber corners (Hatzenbach, Wehrseifen), the Karussell's banked
concrete bowl, and a road 8-9 m wide between barriers (built today at 13 m).

## Two versions stay playable

The current build (`n24_nurburgring`, generated from OpenStreetMap + global elevation) is kept as it
is. Everything this plan produces goes into a **separate track**, `n24_nurburgring_survey`, with its own
recipe (`tools/track/tracks/n24_nurburgring_survey.toml`, started as a copy of `n24_nurburgring.toml`), its own
folder, records and ghosts. Until a race-options row "TRACK DATA: GENERATED / SURVEY" groups
them under one card (a small UI task for the last wave), the survey version is its own card in
the Endurance list. No agent of this plan edits `n24_nurburgring.toml` or `assets/tracks/n24_nurburgring/`.

## Measurable targets

| What | Today | Target |
|---|---|---|
| Elevation source | Terrain Tiles 30 m, sigma 45 m | RLP DGM1 / lidar ground points, 0.25-1 m |
| Crests and jumps | smoothed away | Flugplatz, Pflanzgarten 1 and 2, Brünnchen crests present; car goes light / airborne where real cars do |
| Karussell | flat corner | concrete bowl, measured cross-section, inside line drivable |
| Width | 13 m everywhere | traced, ~8-9 m Nordschleife, GP part ~12-15 m |
| Turns | 99, unofficial placeholder | named corner list (~73 named sections), no fake numbering |
| Trees | random fill | lidar vegetation: real positions and heights along the whole lap |
| Frame rate (HD 520, 1280x720) | measure | >= 50 fps in the forest sections with 10 cars |

## Data (Rhineland-Palatinate, Landesamt für Vermessung und Geobasisinformation, LVermGeo RLP)

To confirm in wave 0 — product names, licence (expected: Datenlizenz Deutschland, dl-de/by-2-0
or zero-2-0) and download interface (GeoPortal RLP / open data portal, WCS or tile downloads):
- **DGM1**: 1 m digital terrain model (ground). Minimum needed for the crests.
- **Laser point clouds** (classified, if published openly): needed for the 0.25 m road grid,
  the Karussell section and real tree positions. If not open, fall back to DGM1 for the road
  (crests still come out; the Karussell section is then modelled by hand from photos and
  published dimensions).
- **DOP20**: 20 cm digital orthophotos (edges, kerbs, run-off, the road graffiti).
- **3D buildings LoD2** (GP circuit buildings, Döttinger Höhe, villages).
Raw tiles cached in `~/.cache/fun-racer/rlp/`, manifest committed in
`assets/tracks/n24_nurburgring/raw/rlp_manifest.json`.

## Differences from the Le Mans plan, per wave

**Wave 0 (1 agent, ~1-2 days).** Confirm which RLP products are open and their interfaces;
downloader (extend `tools/track/lib/ign_data.py` into a generic `survey_data.py` with an IGN and
an RLP backend, or a sibling `rlp_data.py` — whichever keeps the IGN code untouched); fetch the
lap corridor (600 m buffer: about 40-60 km² — report the size before downloading more than
20 GB); quick win: a `dgm1` elevation dataset for the centreline and near terrain if the WCS
allows sampling it like `ahn` (README "Data sources"), rebuild, lap check, compare crests.

**Wave 1 (4 agents).**
- *A, lidar / DGM1 ground model*: as Le Mans, plus a **crest detector** report (vertical
  curvature peaks, with predicted airborne speed `v = sqrt(g / k_v)`) so the jumps can be
  checked against reality (Flugplatz and Pflanzgarten are known jumps, Brünnchen a crest).
  Do NOT smooth the profile with sigma 45 m any more where the lidar is clean: per-stretch
  smoothing only where noise is measured.
- *B, measured cross-sections*: as Le Mans, plus the **Karussell**: the banked inside lane is a
  separate concrete surface (the bowl, about 20-30 degrees, slab joints) next to the flat outer
  road. Build it as a section with a steep inner part; verify the arcade and simulation cars can
  drive the bowl (lap check with the autopilot's racing line through the inside).
- *C, edges from orthophotos AND lidar*: tree canopy hides the road in long stretches, so edges
  also come from the lidar (ground-height break and intensity change at the tarmac edge, and the
  barrier lines, which show as vertical point lines). Merge the two with confidences.
- *D, materials / lighting*: shared with Le Mans (built once; the Nordschleife adds the
  **graffiti layer**: painted names and art on the tarmac, as decals from the orthophoto masks,
  and the concrete Karussell material).

**Physics (new, 1 agent in wave 1).** Jumps and landings: the arcade car must land cleanly
after Flugplatz / Pflanzgarten (no bounce-launch, no wheel tunnelling), and suspension travel
must absorb compressions (Fuchsröhre). Tests: a synthetic crest fixture in
`tests/fixtures/tracks/` with the real crest radius; lap checks on the new geometry in both
handlings, plus airborne time per crest reported by lap_check (add the metric).

**Wave 2 (4 agents).**
- *E, integration*: the 13 m width goes, the 99-turn placeholder is replaced by the named
  sections (Hatzenbach, Hocheichen, Quiddelbacher Höhe, Flugplatz, Schwedenkreuz, Aremberg,
  Fuchsröhre, Adenauer Forst, Metzgesfeld, Kallenhard, Wehrseifen, Breidscheid, Ex-Mühle,
  Bergwerk, Kesselchen, Klostertal, Steilstrecke, Karussell, Hohe Acht, Wippermann, Eschbach,
  Brünnchen, Pflanzgarten, Schwalbenschwanz, Galgenkopf, Döttinger Höhe, Antoniusbuche,
  Tiergarten, Hohenrain, plus the GP part) — names as the "turn" names, without official
  numbers (there are none).
- *F, landmarks*: GP pits and grandstands, the start/finish area, Döttinger Höhe gantry and
  bridges, the B257 / B258 bridges over the track, Breidscheid bridge, the Karussell, Brünnchen
  spectator banks and fences, Nordschleife entry/exit (Touristenfahrten gates), the Nürburg
  castle on the hill as a distant landmark.
- *G, dressing*: armco + catch fences almost everywhere, very close to the road; marshal posts
  (numbered, visible on the photos); kilometre signs; trees from the lidar along the whole lap
  (instanced, LOD), which is most of what the player sees.
- *H, far landscape*: Eifel hills draped with downsampled DOP20, villages from LoD2 buildings.

**Wave 3.** Validation targets: elevation profile vs published figures (lowest Breidscheid
~320 m asl, highest near Hohe Acht ~620 m asl); crest list vs known jumps; lap time with the
endurance car vs a 24h qualifying reference (GT3 at the N24 ~8:10-8:20 on this layout); the
full test suites; a 40-stop screenshot tour; the HD 520 bench in the forest.

## Size

About 2x Le Mans in lap length and harder data (canopy): geometry half ~4-5 weeks, visual half
~4-5 weeks (materials and lighting shared with Le Mans).

## Order of launch

```
W0  ->  W1-A, W1-B (+Karussell), W1-C (+lidar edges), Physics, [W1-D shared]
    ->  W2-E, W2-F, W2-G, W2-H  ->  W3
```

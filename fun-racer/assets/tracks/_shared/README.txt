Shared defaults for track folders that lack a file (see scripts/track/road.gd and
scripts/track/trackside.gd):

- trackside_profiles.json: kerb / armco / concrete wall cross-sections. Track-independent;
  a copy of the file cad/track/trackside_profiles.py writes for the Red Bull Ring.
- road_tarmac.tres, road_grass.tres: materials of the runtime road ribbon (tracks without a
  road_mesh.glb). They reuse the shaders and textures of assets/tracks/red_bull_ring/.

This folder has no track_info.json, so the TrackCatalog does not list it.

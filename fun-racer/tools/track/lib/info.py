"""Road step glue, track_info.json and the track scene template.

The road mesh itself is built by cad/track/road.py (numpy); this module runs it for a track
folder and adds the files that sit next to the mesh: the tarmac / grass materials, the
glb's .import settings and the kerb / barrier profiles.
"""
import json
import os
import re
import shutil
import subprocess
import sys

from .net import BuildError
from .recipe import ROOT

REFERENCE_ID = "red_bull_ring"   # its shaders / materials are the template for new tracks
REFERENCE_DIR = os.path.join(ROOT, "assets", "tracks", REFERENCE_ID)
CAD_DIR = os.path.join(ROOT, "cad", "track")
NOMINAL_WIDTH = 13.0             # m, width stored per point of track.json (see track_json_widths)

SCENE_TEMPLATE = """[gd_scene format=3]

[ext_resource type="Script" path="res://scripts/track/track.gd" id="1_track"]
[ext_resource type="Script" path="res://scripts/track/road.gd" id="2_road"]
[ext_resource type="PackedScene" path="res://assets/tracks/{id}/road_mesh.glb" id="3_glb"]
[ext_resource type="Script" path="res://scripts/track/trackside.gd" id="4_trackside"]
[ext_resource type="Script" path="res://scripts/track/terrain.gd" id="5_terrain"]
[ext_resource type="Script" path="res://scripts/race/race_manager.gd" id="6_race"]

[node name="Track" type="Node3D"]
script = ExtResource("1_track")
track_id = "{id}"
track_json = "res://assets/tracks/{id}/track.json"

[node name="Road" type="Node3D" parent="."]
script = ExtResource("2_road")
profile_path = "res://assets/tracks/{id}/road_profile.json"

[node name="RoadMesh" parent="Road" instance=ExtResource("3_glb")]

[node name="Trackside" type="Node3D" parent="."]
script = ExtResource("4_trackside")

[node name="Terrain" type="Node3D" parent="."]
script = ExtResource("5_terrain")
terrain_json = "res://assets/tracks/{id}/terrain.json"

[node name="Race" type="Node" parent="."]
script = ExtResource("6_race")
"""

GLB_IMPORT_TEMPLATE = """[remap]

importer="scene"
importer_version=1
type="PackedScene"

[deps]

source_file="res://assets/tracks/{id}/road_mesh.glb"

[params]

nodes/root_type=""
nodes/root_name=""
nodes/root_script=null
mesh_library/use_node_names_as_mesh_names=false
array_mesh/deduplicate_surfaces=true
nodes/apply_root_scale=true
nodes/root_scale=1.0
nodes/import_as_skeleton_bones=false
nodes/use_name_suffixes=true
nodes/use_node_type_suffixes=true
meshes/ensure_tangents=false
meshes/generate_lods=false
meshes/create_shadow_meshes=false
meshes/light_baking=0
meshes/lightmap_texel_size=0.2
meshes/force_disable_compression=true
skins/use_named_skins=true
animation/import=true
animation/fps=30
animation/trimming=false
animation/remove_immutable_tracks=true
animation/import_rest_as_RESET=false
import_script/path=""
materials/extract=0
materials/extract_format=0
materials/extract_path=""
_subresources={{
"materials": {{
"grass": {{
"use_external/enabled": true,
"use_external/fallback_path": "res://assets/tracks/{id}/road_grass.tres",
"use_external/path": "res://assets/tracks/{id}/road_grass.tres"
}},
"tarmac": {{
"use_external/enabled": true,
"use_external/fallback_path": "res://assets/tracks/{id}/road_tarmac.tres",
"use_external/path": "res://assets/tracks/{id}/road_tarmac.tres"
}}
}}
}}
gltf/naming_version=2
gltf/embedded_image_handling=1
gltf/texture_map_mode=1
"""


def _load_road_module():
    if CAD_DIR not in sys.path:
        sys.path.insert(0, CAD_DIR)
    try:
        import road  # noqa: E402  (cad/track/road.py)
    except ImportError as e:
        raise BuildError(f"the road step needs numpy ({e}). Run it with the project venv: "
                         "python3 -m venv .venv && .venv/bin/pip install -r cad/requirements.txt") from e
    return road


def _write_materials(recipe, track, out_dir, log):
    """Shaders, materials and the glb import settings for a new track, copied from the
    reference track with the paths (and the lap constants of the painted lines) replaced.
    Existing files are left alone, so hand-tuned materials survive a rebuild."""
    ref = f"res://assets/tracks/{REFERENCE_ID}/"
    new = f"res://assets/tracks/{recipe.id}/"
    made = []
    for name in ("road_tarmac.gdshader", "road_grass.gdshader", "road_tarmac.tres", "road_grass.tres"):
        dst = os.path.join(out_dir, name)
        src = os.path.join(REFERENCE_DIR, name)
        if os.path.exists(dst):
            continue
        if not os.path.exists(src):
            log(f"  note: {name} not written, the reference file {os.path.relpath(src, ROOT)} is gone "
                "(the runtime may now share one material for all tracks)")
            continue
        with open(src, encoding="utf-8") as f:
            text = f.read().replace(ref, new)
        if name == "road_tarmac.gdshader":
            text = text.replace("// Red Bull Ring tarmac", f"// {recipe.name} tarmac")
            # Defaults for the painted start / finish lines and grid; scripts/track/road.gd
            # also sets them from track.json at load time.
            text = re.sub(r"(uniform float track_length = )[0-9.]+;", rf"\g<1>{track['length']:.3f};", text)
            text = re.sub(r"(uniform float start_s = )[0-9.]+;", rf"\g<1>{track['start_s']:.3f};", text)
        with open(dst, "w", encoding="utf-8") as f:
            f.write(text)
        made.append(name)
    # Texture import settings (mipmaps on): the reference ones without the lines Godot derives
    # from the path (uid, imported file names), which it fills in on the first import.
    for name in ("road_tarmac_albedo.png.import", "road_grass_albedo.png.import"):
        dst = os.path.join(out_dir, name)
        src = os.path.join(REFERENCE_DIR, name)
        if os.path.exists(dst) or not os.path.exists(src):
            continue
        with open(src, encoding="utf-8") as f:
            lines = [ln.replace(ref, new) for ln in f if not ln.startswith(("uid=", "path=", "dest_files="))]
        with open(dst, "w", encoding="utf-8") as f:
            f.writelines(lines)
        made.append(name)
    dst = os.path.join(out_dir, "road_mesh.glb.import")
    if not os.path.exists(dst):
        with open(dst, "w", encoding="utf-8") as f:
            f.write(GLB_IMPORT_TEMPLATE.format(id=recipe.id))
        made.append("road_mesh.glb.import")
    if made:
        log("  materials: wrote " + ", ".join(made))


def _write_trackside_profiles(out_dir, log):
    """Kerb / barrier cross-sections: the same for every track (cad/track/trackside_profiles.py).
    Written once; delete the file to regenerate it (build123d, ~15 s)."""
    dst = os.path.join(out_dir, "trackside_profiles.json")
    if os.path.exists(dst):
        return
    script = os.path.join(CAD_DIR, "trackside_profiles.py")
    try:
        subprocess.run([sys.executable, script, dst], check=True, capture_output=True, text=True, timeout=600)
        return
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, OSError) as e:
        reason = (getattr(e, "stderr", "") or str(e)).strip().splitlines()[-1:]
    src = os.path.join(REFERENCE_DIR, "trackside_profiles.json")
    if os.path.abspath(src) == os.path.abspath(dst) and os.path.exists(dst):
        log(f"  trackside_profiles.json kept as is (generator failed: {' '.join(reason)})")
    elif os.path.exists(src):
        shutil.copyfile(src, dst)
        log(f"  trackside_profiles.json copied from {REFERENCE_ID} (generator failed: {' '.join(reason)})")
    else:
        raise BuildError(f"cannot generate trackside_profiles.json: {' '.join(reason)}")


def build_road(recipe, out_dir, log=print):
    road = _load_road_module()
    from pathlib import Path
    with open(os.path.join(out_dir, "track.json"), encoding="utf-8") as f:
        track = json.load(f)
    _check_track_widths(recipe, track)
    try:
        res = road.build(Path(out_dir) / "track.json", Path(out_dir), recipe.road, recipe.id)
    except ValueError as e:
        raise BuildError(f"road: {e}") from e
    except AssertionError as e:
        raise BuildError(f"road: the mesh could not be built ({e}). The centreline probably "
                         "crosses itself or folds; see 'Known limits' in tools/track/README.md") from e
    log(f"road: {res['chunks']} chunks, {res['triangles']} triangles; width {res['width'][0]:.1f}-"
        f"{res['width'][1]:.1f} m, bank {res['bank'][0]:+.3f}..{res['bank'][1]:+.3f} rad, "
        f"min verge {res['verge_min']:.1f} m" + ("" if recipe.road.get("bank_keys") else "  (automatic camber)"))
    for note in res.get("notes", []):
        log(f"  banking: {note}")
    for b in res.get("bridges", []):
        log(f"  bridge: deck s = {b['deck'][0]:.0f} to {b['deck'][1]:.0f} m ({b['span'][0]:.0f} to "
            f"{b['span'][1]:.0f} m above open ground), {b['clearance']:.1f} m over the road at "
            f"s = {b['s_lower']:.0f} m")
    if res.get("wall_length"):
        log(f"  retaining walls: {res['wall_length']:.0f} m ([road] retaining_walls)")
    _write_materials(recipe, track, out_dir, log)
    _write_trackside_profiles(out_dir, log)
    return res


def road_widths(recipe, n, step, length, start_s, curvature):
    """Width of the road the 'road' step builds, per centreline point (m, rounded to 1 mm):
    the recipe's [road] table through cad/track/banking.py."""
    _load_road_module()
    import banking  # noqa: E402  (cad/track/banking.py, on sys.path now)
    import numpy as np
    try:
        _, width = banking.profile(np.arange(n) * step, length, np.asarray(curvature, dtype=float),
                                   start_s, recipe.road)
    except ValueError as e:
        raise BuildError(f"road: {e}") from e
    return [round(float(w), 3) for w in width]


def track_json_widths(recipe, n, step, length, start_s, curvature):
    """The ``width`` of every point of track.json. Normally a nominal 13 m, whatever the road
    step builds: the real widths are in road_profile.json. The game's drivers (the autopilot's
    racing line, the bots' off-road test) read track.json, though, so a road built narrower
    than that must say so there: with ``[road] track_json_widths = true`` these are the built
    widths. Opt-in, so that the tracks built before the key existed stay byte for byte the same."""
    if not recipe.road.get("track_json_widths"):
        # Never promise more road than the recipe's base width: the drivers plan inside it.
        # (A stretch narrowed further needs track_json_widths = true.)
        return [min(NOMINAL_WIDTH, float(recipe.road.get("base_width", NOMINAL_WIDTH)))] * n
    return road_widths(recipe, n, step, length, start_s, curvature)


def _check_track_widths(recipe, track):
    """track.json is written by the centreline step, and its widths depend on the [road] table:
    stop if the two no longer agree (the table or track_json_widths changed since it ran)."""
    pts = track["points"]
    want = track_json_widths(recipe, len(pts), float(track["step"]), float(track["length"]),
                             float(track.get("start_s", 0.0)), [p.get("curvature", 0.0) for p in pts])
    worst = max(abs(float(p.get("width", w)) - w) for p, w in zip(pts, want))
    if worst > 2e-3:
        raise BuildError(f"road: the widths in track.json differ by up to {worst:.2f} m from the "
                         "recipe's [road] table (its widths or track_json_widths changed since the "
                         "centreline step ran). Run the build again with the 'centreline' step.")


def write_track_info(recipe, out_dir, scene_dir, log=print):
    """track_info.json (what the menu lists) and, if missing, a minimal track scene."""
    with open(os.path.join(out_dir, "track.json"), encoding="utf-8") as f:
        track = json.load(f)
    available = all(os.path.exists(os.path.join(out_dir, n))
                    for n in ("road_mesh.glb", "road_profile.json", "terrain.json", "terrain_height.bin"))
    info = {
        "id": recipe.id,
        "name": recipe.name,
        "grand_prix": recipe.grand_prix,
        "country": recipe.country,
        "country_code": recipe.country_code,
        "city": recipe.city,
        "length_m": int(recipe.length_m) if float(recipe.length_m).is_integer() else recipe.length_m,
        "turns": recipe.turns or len(track["turns"]),
        "scene": f"res://scenes/tracks/{recipe.id}.tscn",
        "track_json": f"res://assets/tracks/{recipe.id}/track.json",
        "osm_relation": recipe.osm_relation,
        "available": available,
    }
    with open(os.path.join(out_dir, "track_info.json"), "w", encoding="utf-8") as f:
        json.dump(info, f, indent=2, ensure_ascii=False)
        f.write("\n")
    scene = os.path.join(scene_dir, f"{recipe.id}.tscn")
    if os.path.exists(scene):
        log(f"info: track_info.json (available: {str(available).lower()}); scene {os.path.basename(scene)} kept")
    else:
        os.makedirs(scene_dir, exist_ok=True)
        with open(scene, "w", encoding="utf-8") as f:
            f.write(SCENE_TEMPLATE.format(id=recipe.id))
        log(f"info: track_info.json (available: {str(available).lower()}); wrote scene {scene}")
    return info

"""Per-track build recipe: everything the pipeline cannot derive from open data.

A recipe is a TOML file, tools/track/tracks/<id>.toml (see tools/track/README.md for the full
reference). Every key is optional except the OSM source and the official length, and those
too can come from the command line / assets/tracks/calendar.json:

    name = "Red Bull Ring"            # default: calendar.json entry for the id
    length_m = 4318                   # official lap length
    turns = 10                        # official turn count

    [osm]
    relation = 5309181                # or: ways = [..ordered loop..]  /  bbox = [w, s, e, n]
    exclude_ways = [123]

    [layout]
    direction = "clockwise"
    finish = [47.2203, 14.7667]       # lat, lon of the finish line
    sectors = [2352.2, 3219.5]

    [[turn]]                          # names only, or pinned apex positions with `s`
    id = "T3"
    name = "Remus"

    [road]
    base_width = 13.0
    [[road.override]]
    s = [1200, 1400]
    width = 15.0
"""
import json
import os
import re
import tomllib
from dataclasses import dataclass, field

from .net import BuildError

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
CALENDAR = os.path.join(ROOT, "assets", "tracks", "calendar.json")
RECIPE_DIR = os.path.join(ROOT, "tools", "track", "tracks")

TOP_KEYS = {"id", "name", "full_name", "grand_prix", "country", "country_code", "city", "length_m",
            "turns", "osm", "layout", "elevation", "turn", "road", "terrain", "surroundings"}
SECTION_KEYS = {
    "surroundings": {"margin_m", "far_margin_m", "default_levels", "level_height_m", "tree_density",
                     "tree_species", "building", "exclude", "add", "roof"},
    "osm": {"relation", "ways", "bbox", "exclude_ways", "extra_ways", "avoid_nodes", "avoid_names",
            "ignore_oneway", "length_tolerance", "round"},
    "layout": {"direction", "finish", "start", "start_offset_m", "sectors", "spline"},
    "elevation": {"dataset", "smooth_sigma_m", "override"},
    "road": {"base_width", "grid_width", "crossfall", "camber_gain", "bank_keys", "width_keys",
             "override", "track_json_widths", "retaining_walls"},
    "terrain": {"near", "far", "smooth_sigma_m"},
}
TURN_KEYS = {"id", "name", "direction", "s"}
OVERRIDE_KEYS = {"s", "width", "bank", "blend", "note"}
ELEV_OVERRIDE_KEYS = {"s", "offset", "straighten", "blend", "note"}
ROUND_KEYS = {"node", "to_node", "reach_m", "note"}
DIRECTIONS = {"clockwise", "anticlockwise"}


@dataclass
class Recipe:
    id: str
    name: str = ""
    full_name: str = ""
    grand_prix: str = ""
    country: str = ""
    country_code: str = ""
    city: str = ""
    length_m: float = 0.0
    turns: int | None = None
    # [osm]
    osm_relation: int | None = None
    osm_ways: list = field(default_factory=list)
    osm_bbox: list | None = None
    exclude_ways: list = field(default_factory=list)
    extra_ways: list = field(default_factory=list)   # ways the relation / box lacks
    avoid_nodes: list = field(default_factory=list)  # nodes the lap must not pass through
    avoid_names: list = field(default_factory=list)
    ignore_oneway: bool = False
    length_tolerance: float = 0.03
    osm_round: list = field(default_factory=list)   # [[osm.round]]: {node, reach_m, to_node, note}
    # [layout]
    direction: str | None = None
    finish: list | None = None
    start: list | None = None
    start_offset_m: float | None = None
    sectors: list | None = None
    spline: str = "centripetal"
    # [elevation]
    dem_dataset: str | None = None
    elev_sigma_m: float = 45.0
    elev_overrides: list = field(default_factory=list)   # [[elevation.override]], see centreline.py
    # [[turn]]
    turn_table: list = field(default_factory=list)
    # [road], [terrain]: plain dicts, read by cad/track/banking.py and lib/terrain.py
    road: dict = field(default_factory=dict)
    terrain: dict = field(default_factory=dict)
    surroundings: dict = field(default_factory=dict)   # [surroundings], read by lib/surroundings.py
    source: str = ""

    @property
    def turns_pinned(self):
        return bool(self.turn_table) and all("s" in t for t in self.turn_table)


def calendar_entry(track_id, calendar_path=CALENDAR):
    try:
        with open(calendar_path, encoding="utf-8") as f:
            cal = json.load(f)
    except OSError:
        return {}
    return next((t for t in cal.get("tracks", []) if t.get("id") == track_id), {})


def _check_keys(where, d, allowed):
    unknown = sorted(set(d) - allowed)
    if unknown:
        raise BuildError(f"recipe: unknown key(s) {', '.join(unknown)} in {where} "
                         f"(allowed: {', '.join(sorted(allowed))})")


def _latlon(where, v):
    if v is None:
        return None
    if (not isinstance(v, list) or len(v) != 2 or not all(isinstance(x, (int, float)) for x in v)
            or not -90.0 <= v[0] <= 90.0 or not -180.0 <= v[1] <= 180.0):
        raise BuildError(f"recipe: {where} must be [lat, lon] in degrees")
    return [float(v[0]), float(v[1])]


def from_dict(track_id, data, overrides=None, calendar_path=CALENDAR, source=""):
    """Recipe from parsed TOML ``data``, filled in from calendar.json and then from
    ``overrides`` (command-line values; None entries are ignored)."""
    if not re.fullmatch(r"[a-z0-9][a-z0-9_]*", track_id or ""):
        raise BuildError(f"track id '{track_id}' must be lower-case letters, digits and underscores")
    data = dict(data)
    _check_keys("the recipe", data, TOP_KEYS)
    if data.get("id", track_id) != track_id:
        raise BuildError(f"recipe id '{data['id']}' does not match the requested track '{track_id}'")
    for sec, allowed in SECTION_KEYS.items():
        if not isinstance(data.get(sec, {}), dict):
            raise BuildError(f"recipe: [{sec}] must be a table")
        _check_keys(f"[{sec}]", data.get(sec, {}), allowed)
    cal = calendar_entry(track_id, calendar_path)
    osm, lay, elev = data.get("osm", {}), data.get("layout", {}), data.get("elevation", {})

    def meta(key, default=""):
        return data.get(key, cal.get(key, default))

    r = Recipe(
        id=track_id, name=meta("name", track_id.replace("_", " ").title()),
        grand_prix=meta("grand_prix"), country=meta("country"),
        country_code=meta("country_code"), city=meta("city"),
        length_m=float(meta("length_m", 0.0)), turns=meta("turns", None),
        osm_relation=osm.get("relation"), osm_ways=list(osm.get("ways", [])),
        osm_bbox=osm.get("bbox"), exclude_ways=list(osm.get("exclude_ways", [])),
        extra_ways=list(osm.get("extra_ways", [])),
        avoid_nodes=list(osm.get("avoid_nodes", [])),
        avoid_names=list(osm.get("avoid_names", [])),
        ignore_oneway=bool(osm.get("ignore_oneway", False)),
        length_tolerance=float(osm.get("length_tolerance", 0.03)),
        osm_round=osm.get("round", []),
        direction=lay.get("direction"), finish=_latlon("layout.finish", lay.get("finish")),
        start=_latlon("layout.start", lay.get("start")),
        start_offset_m=lay.get("start_offset_m"), sectors=lay.get("sectors"),
        spline=lay.get("spline", "centripetal"),
        dem_dataset=elev.get("dataset"), elev_sigma_m=float(elev.get("smooth_sigma_m", 45.0)),
        elev_overrides=[dict(o) for o in elev.get("override", [])],
        turn_table=[dict(t) for t in data.get("turn", [])],
        road=dict(data.get("road", {})), terrain=dict(data.get("terrain", {})),
        surroundings=dict(data.get("surroundings", {})), source=source)
    for k, v in (overrides or {}).items():
        if v is not None:
            setattr(r, k, v)
    r.full_name = data.get("full_name") or f"{r.name} (Grand Prix circuit)"
    validate(r)
    return r


SURR_BUILDING_KEYS = {"osm", "height", "levels", "type", "remove", "note"}
SURR_EXCLUDE_KEYS = {"osm", "polygon", "note"}
SURR_ADD_KEYS = {"polygon", "height", "min_height", "kind", "note"}
SURR_ROOF_KEYS = {"s", "clear_height", "kind", "note"}
SURR_ADD_KINDS = {"building", "glass", "grandstand", "concrete", "metal", "screen", "light",   # solids
                  "grass", "forest", "water", "sand", "paved", "farmland", "rock", "gravel",   # ground
                  "scrub", "beach"}
SURR_ROOF_KINDS = {"tunnel", "overpass", "gallery_left", "gallery_right"}
SURR_TREE_SPECIES = {"mixed", "broadleaved", "needleleaved", "palm"}


def _number(v, lo, hi):
    return isinstance(v, (int, float)) and not isinstance(v, bool) and lo <= v <= hi


def _osm_ref(v):
    """An OSM object of the surroundings: a bare id (way or relation) or "way/123"."""
    return (isinstance(v, int) and not isinstance(v, bool) and v > 0) or (
        isinstance(v, str) and re.fullmatch(r"(node|way|relation)/[1-9][0-9]*", v) is not None)


def _latlon_ring(v):
    return (isinstance(v, list) and len(v) >= 3
            and all(isinstance(p, list) and len(p) == 2 and _number(p[0], -90.0, 90.0)
                    and _number(p[1], -180.0, 180.0) for p in v))


def validate_surroundings(r):
    """[surroundings]: see lib/surroundings.py for what the keys do."""
    sur = r.surroundings
    for key, lo, hi in (("margin_m", 50.0, 2000.0), ("far_margin_m", 0.0, 6000.0),
                        ("default_levels", 1, 60), ("level_height_m", 2.0, 6.0),
                        ("tree_density", 0.0, 1000.0)):
        if key in sur and not _number(sur[key], lo, hi):
            raise BuildError(f"recipe: surroundings.{key} must be a number between {lo} and {hi}")
    def one_of(v, allowed):
        return isinstance(v, str) and v in allowed

    if not one_of(sur.get("tree_species", "mixed"), SURR_TREE_SPECIES):
        raise BuildError("recipe: surroundings.tree_species must be one of "
                         + ", ".join(sorted(SURR_TREE_SPECIES)))
    tables = {}
    for key, allowed in (("building", SURR_BUILDING_KEYS), ("exclude", SURR_EXCLUDE_KEYS),
                         ("add", SURR_ADD_KEYS), ("roof", SURR_ROOF_KEYS)):
        tables[key] = sur.get(key, [])
        if not isinstance(tables[key], list) or not all(isinstance(o, dict) for o in tables[key]):
            raise BuildError(f"recipe: surroundings.{key} must be written as [[surroundings.{key}]] tables")
        for o in tables[key]:
            _check_keys(f"[[surroundings.{key}]]", o, allowed)
    for o in tables["building"]:
        if not _osm_ref(o.get("osm")) or not ({"height", "levels", "type", "remove"} & set(o)):
            raise BuildError("recipe: [[surroundings.building]] needs osm = <way or relation id> and "
                             "a height, levels, type and/or remove = true")
        if (("height" in o and not _number(o["height"], 0.5, 1000.0))
                or ("levels" in o and not _number(o["levels"], 1, 250))
                or ("type" in o and not isinstance(o["type"], str))
                or not isinstance(o.get("remove", False), bool)):
            raise BuildError("recipe: [[surroundings.building]] height is metres, levels a count, "
                             "type a building=* value, remove true / false")
    for o in tables["exclude"]:
        if ("osm" in o) == ("polygon" in o) or ("osm" in o and not _osm_ref(o["osm"])) or (
                "polygon" in o and not _latlon_ring(o["polygon"])):
            raise BuildError("recipe: [[surroundings.exclude]] needs either osm = <id> or "
                             "polygon = [[lat, lon], ...] (3 points or more)")
    for o in tables["add"]:
        if not _latlon_ring(o.get("polygon")) or not one_of(o.get("kind", "building"), SURR_ADD_KINDS):
            raise BuildError("recipe: [[surroundings.add]] needs polygon = [[lat, lon], ...] and a "
                             "kind out of " + ", ".join(sorted(SURR_ADD_KINDS)))
        if (("height" in o and not _number(o["height"], 0.2, 1000.0))
                or ("min_height" in o and not _number(o["min_height"], 0.0, 1000.0))):
            raise BuildError("recipe: [[surroundings.add]] height and min_height are metres")
        if "height" in o and o.get("min_height", 0.0) >= o["height"]:
            raise BuildError("recipe: [[surroundings.add]] min_height must be below height (both "
                             "are measured from the ground)")
    for o in tables["roof"]:
        s = o.get("s")
        if (not isinstance(s, list) or len(s) != 2 or not all(_number(x, 0.0, r.length_m) for x in s)
                or s[0] == s[1] or s[0] >= r.length_m or s[1] >= r.length_m):
            raise BuildError("recipe: [[surroundings.roof]] needs s = [from, to] inside the lap")
        if "clear_height" in o and not _number(o["clear_height"], 2.5, 40.0):
            raise BuildError("recipe: [[surroundings.roof]] clear_height is metres (2.5 to 40)")
        if not one_of(o.get("kind", "tunnel"), SURR_ROOF_KINDS):
            raise BuildError("recipe: [[surroundings.roof]] kind must be one of "
                             + ", ".join(sorted(SURR_ROOF_KINDS)))


def validate(r):
    if r.length_m <= 0.0:
        raise BuildError(f"no official lap length for '{r.id}': it is not in assets/tracks/"
                         "calendar.json, so give length_m in the recipe or --length")
    if not 500.0 <= r.length_m <= 30000.0:
        raise BuildError(f"length_m = {r.length_m} m is not a plausible lap length")
    validate_surroundings(r)
    if r.turns is not None and (not isinstance(r.turns, int) or r.turns < 1):
        raise BuildError("recipe: turns must be a positive integer")
    if sum(bool(x) for x in (r.osm_relation, r.osm_ways, r.osm_bbox)) == 0:
        raise BuildError(f"no OSM source for '{r.id}': give --osm-relation N, or [osm] relation / "
                         "ways / bbox in the recipe (see tools/track/README.md)")
    if r.osm_bbox is not None:
        b = r.osm_bbox
        if (not isinstance(b, list) or len(b) != 4 or not all(isinstance(x, (int, float)) for x in b)
                or not (b[0] < b[2] and b[1] < b[3])):
            raise BuildError("recipe: osm.bbox must be [west, south, east, north] in degrees")
    for name in ("osm_ways", "exclude_ways", "extra_ways", "avoid_nodes"):
        if not all(isinstance(w, int) and not isinstance(w, bool) for w in getattr(r, name)):
            raise BuildError(f"recipe: osm {name.replace('osm_', '')} must be a list of "
                             f"{'node' if name == 'avoid_nodes' else 'way'} ids")
    if r.osm_ways and (r.extra_ways or r.avoid_nodes):
        raise BuildError("recipe: osm.extra_ways / avoid_nodes steer the loop search and have no "
                         "effect on an explicit osm.ways list; remove one or the other")
    if not isinstance(r.road.get("retaining_walls", False), bool):
        raise BuildError("recipe: road.retaining_walls must be true or false")
    if r.direction is not None and r.direction not in DIRECTIONS:
        raise BuildError("recipe: layout.direction must be 'clockwise' or 'anticlockwise'")
    if r.spline not in ("centripetal", "uniform"):
        raise BuildError("recipe: layout.spline must be 'centripetal' or 'uniform'")
    if not isinstance(r.osm_round, list) or not all(isinstance(o, dict) for o in r.osm_round):
        raise BuildError("recipe: osm.round must be written as [[osm.round]] tables")
    for o in r.osm_round:
        _check_keys("[[osm.round]]", o, ROUND_KEYS)
        node, reach = o.get("node"), o.get("reach_m")
        if (not isinstance(node, int) or isinstance(node, bool) or isinstance(reach, bool)
                or not isinstance(reach, (int, float)) or not 1.0 <= reach <= 500.0):
            raise BuildError("recipe: [[osm.round]] needs node = <OSM node id> and reach_m = "
                             "<metres, 1 to 500>")
        to_node = o.get("to_node")
        if to_node is not None and (not isinstance(to_node, int) or isinstance(to_node, bool)
                                    or to_node == node):
            raise BuildError("recipe: [[osm.round]] to_node must be another OSM node id")
    if not 0.0 < r.length_tolerance < 0.5:
        raise BuildError("recipe: osm.length_tolerance is a fraction, e.g. 0.03")
    if r.sectors is not None:
        s = r.sectors
        if len(s) == 3 and s[0] == 0:
            s = s[1:]
        if (len(s) != 2 or not all(isinstance(x, (int, float)) for x in s)
                or not 0.0 < s[0] < s[1] < r.length_m):
            raise BuildError("recipe: layout.sectors must be [s1, s2], the distances in metres "
                             "where sectors 2 and 3 begin")
        r.sectors = [float(s[0]), float(s[1])]
    ids = set()
    for t in r.turn_table:
        _check_keys("[[turn]]", t, TURN_KEYS)
        if "id" not in t or not re.fullmatch(r"T[1-9][0-9]*", str(t["id"])):
            raise BuildError("recipe: every [[turn]] needs an id like \"T3\"")
        if t["id"] in ids:
            raise BuildError(f"recipe: turn {t['id']} is listed twice")
        ids.add(t["id"])
        if "direction" in t and t["direction"] not in ("left", "right"):
            raise BuildError(f"recipe: turn {t['id']} direction must be 'left' or 'right'")
        if "s" in t and not 0.0 <= float(t["s"]) < r.length_m:
            raise BuildError(f"recipe: turn {t['id']} s is outside the lap")
    pinned = [t for t in r.turn_table if "s" in t]
    if pinned and len(pinned) != len(r.turn_table):
        raise BuildError("recipe: either every [[turn]] has an `s` (the table then replaces the "
                         "automatic detection) or none has (names only)")
    if pinned:
        order = [float(t["s"]) for t in r.turn_table]
        if order != sorted(order) or [t["id"] for t in r.turn_table] != [f"T{i + 1}" for i in range(len(pinned))]:
            raise BuildError("recipe: pinned [[turn]] entries must be T1..Tn in lap order")
        if any("direction" not in t for t in r.turn_table):
            raise BuildError("recipe: pinned [[turn]] entries need a direction")
    for key in ("bank_keys", "width_keys"):
        keys = r.road.get(key)
        if keys is None:
            continue
        ok = isinstance(keys, list) and len(keys) >= 2 and all(
            isinstance(k, list) and len(k) in (2, 3) and all(isinstance(x, (int, float)) for x in k[:2])
            for k in keys)
        if not ok or [k[0] for k in keys] != sorted({k[0] for k in keys}) or keys[-1][0] >= r.length_m or keys[0][0] < 0:
            raise BuildError(f"recipe: road.{key} must be [[s, value, \"note\"], ...] with s "
                             "ascending inside the lap")
    for key, lo, hi in (("crossfall", 0.0, 0.03), ("camber_gain", 0.0, 10.0), ("base_width", 6.0, 30.0),
                        ("grid_width", 6.0, 30.0)):
        v = r.road.get(key)
        if v is not None and (not isinstance(v, (int, float)) or not lo <= v <= hi):
            raise BuildError(f"recipe: road.{key} must be a number between {lo} and {hi}"
                             + (" (radians; 0.015 = 1.5 %)" if key == "crossfall" else ""))
    if not isinstance(r.road.get("track_json_widths", False), bool):
        raise BuildError("recipe: road.track_json_widths must be true or false")
    for o in r.road.get("override", []):
        _check_keys("[[road.override]]", o, OVERRIDE_KEYS)
        s = o.get("s")
        if (not isinstance(s, list) or len(s) != 2 or not all(isinstance(x, (int, float)) for x in s)
                or "width" not in o and "bank" not in o):
            raise BuildError("recipe: [[road.override]] needs s = [from, to] and a width and/or bank")
    for o in r.elev_overrides:
        _check_keys("[[elevation.override]]", o, ELEV_OVERRIDE_KEYS)
        s = o.get("s")
        if (not isinstance(s, list) or len(s) != 2 or not all(isinstance(x, (int, float)) for x in s)
                or not all(0.0 <= x < r.length_m for x in s) or s[0] == s[1]
                or not (o.get("straighten") or o.get("offset"))):
            raise BuildError("recipe: [[elevation.override]] needs s = [from, to] inside the lap and "
                             "an offset (metres) and/or straighten = true")
        if (not isinstance(o.get("offset", 0.0), (int, float)) or not isinstance(o.get("straighten", False), bool)
                or not isinstance(o.get("blend", 0.0), (int, float)) or o.get("blend", 0.0) < 0.0):
            raise BuildError("recipe: [[elevation.override]] offset and blend are metres (blend >= 0), "
                             "straighten is true / false")
    for key in ("near", "far"):
        b = r.terrain.get(key)
        if b is not None and (not isinstance(b, list) or len(b) != 4 or not (b[0] < b[1] and b[2] < b[3])):
            raise BuildError(f"recipe: terrain.{key} must be [x0, x1, z0, z1] in metres")
    sigma = r.terrain.get("smooth_sigma_m")
    if sigma is not None and (isinstance(sigma, bool) or not isinstance(sigma, (int, float)) or sigma < 0):
        raise BuildError("recipe: terrain.smooth_sigma_m must be a distance in metres (0 or more)")


def load(track_id, path=None, overrides=None, calendar_path=CALENDAR):
    """Recipe for ``track_id`` from ``path`` (default tools/track/tracks/<id>.toml; a missing
    default file just means "no overrides")."""
    data, source = {}, ""
    default = os.path.join(RECIPE_DIR, f"{track_id}.toml")
    if path is None and os.path.exists(default):
        path = default
    if path is not None:
        try:
            with open(path, "rb") as f:
                data = tomllib.load(f)
        except OSError as e:
            raise BuildError(f"cannot read recipe {path}: {e}") from e
        except tomllib.TOMLDecodeError as e:
            raise BuildError(f"recipe {path} is not valid TOML: {e}") from e
        source = os.path.relpath(path, ROOT) if os.path.abspath(path).startswith(ROOT) else str(path)
    return from_dict(track_id, data, overrides, calendar_path, source)

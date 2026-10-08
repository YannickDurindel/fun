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
            "turns", "osm", "layout", "elevation", "turn", "road", "terrain"}
SECTION_KEYS = {
    "osm": {"relation", "ways", "bbox", "exclude_ways", "avoid_names", "ignore_oneway",
            "length_tolerance"},
    "layout": {"direction", "finish", "start", "start_offset_m", "sectors", "spline"},
    "elevation": {"dataset", "smooth_sigma_m"},
    "road": {"base_width", "grid_width", "crossfall", "camber_gain", "bank_keys", "width_keys",
             "override"},
    "terrain": {"near", "far", "smooth_sigma_m"},
}
TURN_KEYS = {"id", "name", "direction", "s"}
OVERRIDE_KEYS = {"s", "width", "bank", "blend", "note"}
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
    avoid_names: list = field(default_factory=list)
    ignore_oneway: bool = False
    length_tolerance: float = 0.03
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
    # [[turn]]
    turn_table: list = field(default_factory=list)
    # [road], [terrain]: plain dicts, read by cad/track/banking.py and lib/terrain.py
    road: dict = field(default_factory=dict)
    terrain: dict = field(default_factory=dict)
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
        avoid_names=list(osm.get("avoid_names", [])),
        ignore_oneway=bool(osm.get("ignore_oneway", False)),
        length_tolerance=float(osm.get("length_tolerance", 0.03)),
        direction=lay.get("direction"), finish=_latlon("layout.finish", lay.get("finish")),
        start=_latlon("layout.start", lay.get("start")),
        start_offset_m=lay.get("start_offset_m"), sectors=lay.get("sectors"),
        spline=lay.get("spline", "centripetal"),
        dem_dataset=elev.get("dataset"), elev_sigma_m=float(elev.get("smooth_sigma_m", 45.0)),
        turn_table=[dict(t) for t in data.get("turn", [])],
        road=dict(data.get("road", {})), terrain=dict(data.get("terrain", {})), source=source)
    for k, v in (overrides or {}).items():
        if v is not None:
            setattr(r, k, v)
    r.full_name = data.get("full_name") or f"{r.name} (Grand Prix circuit)"
    validate(r)
    return r


def validate(r):
    if r.length_m <= 0.0:
        raise BuildError(f"no official lap length for '{r.id}': it is not in assets/tracks/"
                         "calendar.json, so give length_m in the recipe or --length")
    if not 500.0 <= r.length_m <= 30000.0:
        raise BuildError(f"length_m = {r.length_m} m is not a plausible lap length")
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
    for name in ("osm_ways", "exclude_ways"):
        if not all(isinstance(w, int) for w in getattr(r, name)):
            raise BuildError(f"recipe: osm {name.replace('osm_', '')} must be a list of way ids")
    if r.direction is not None and r.direction not in DIRECTIONS:
        raise BuildError("recipe: layout.direction must be 'clockwise' or 'anticlockwise'")
    if r.spline not in ("centripetal", "uniform"):
        raise BuildError("recipe: layout.spline must be 'centripetal' or 'uniform'")
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
    for o in r.road.get("override", []):
        _check_keys("[[road.override]]", o, OVERRIDE_KEYS)
        s = o.get("s")
        if (not isinstance(s, list) or len(s) != 2 or not all(isinstance(x, (int, float)) for x in s)
                or "width" not in o and "bank" not in o):
            raise BuildError("recipe: [[road.override]] needs s = [from, to] and a width and/or bank")
    for key in ("near", "far"):
        b = r.terrain.get(key)
        if b is not None and (not isinstance(b, list) or len(b) != 4 or not (b[0] < b[1] and b[2] < b[3])):
            raise BuildError(f"recipe: terrain.{key} must be [x0, x1, z0, z1] in metres")
    sigma = r.terrain.get("smooth_sigma_m", 0.0)
    if isinstance(sigma, bool) or not isinstance(sigma, (int, float)) or not 0 <= sigma < 10000:
        raise BuildError("recipe: terrain.smooth_sigma_m must be a number of metres, from 0 to 10000")


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

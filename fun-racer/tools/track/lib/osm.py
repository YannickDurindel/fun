"""OpenStreetMap access: fetch a circuit, and find the closed Grand Prix loop in it.

Three sources, in order of preference:
  * a ``type=circuit`` relation (its member ways; members with a pit / penalty / joker role
    are dropped),
  * an explicit list of way ids (chained in the order given: the manual fallback),
  * a bounding box (every ``highway=raceway`` way inside it).

The loop is found without a hand-written way list: the ways are split at the nodes they
share, which gives a small directed graph (``oneway`` gives the direction), every simple
cycle of it is a candidate lap, and the cycle whose length is closest to the official lap
length wins. Pit lanes and alternative layouts are penalised by name.
"""
import hashlib
import math
import re
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field

from .geom import EARTH_M_PER_DEG
from .net import OSM_API, BuildError

PIT_RE = re.compile(r"\bpits?\b|pit[ _-]?(lane|stra)|boxen|\bbox(es)?\b|bokszutca|\bstands\b", re.I)
ALT_RE = re.compile(r"moto ?gp|motorcycle|motorbike|\bbikes?\b|kart|long ?lap|penalty|joker|"
                    r"rallycross|short ?cut|cutting|\bclub\b|\bnational\b|\bschool\b|drag ?strip|"
                    r"escape|run-?off|\bservice\b|\baccess\b|\bcross\b|\boval\b", re.I)
# "Pit Straight", "Boxengerade": part of the lap, not the pit lane.
STRAIGHT_RE = re.compile(r"straight|gerade|rettilineo|rettifilo|recta\b|ligne droite", re.I)
EXCLUDE_ROLE_RE = re.compile(r"pit|penalty|joker|escape|service|alternat|short", re.I)
PIT_PENALTY = 1.0     # added to the relative length error, times the pit share of the lap
ALT_PENALTY = 0.05    # flat penalty for using any alternative-layout way
AMBIGUOUS = 0.003     # two different laps scoring this close cannot be told apart
MAX_STEPS = 400000    # cycle search budget


@dataclass
class Way:
    id: int
    nodes: list
    tags: dict

    @property
    def name(self):
        return self.tags.get("name", "")


@dataclass
class OsmData:
    nodes: dict = field(default_factory=dict)        # id -> (lat, lon)
    node_tags: dict = field(default_factory=dict)    # id -> tags (tagged nodes only)
    ways: dict = field(default_factory=dict)         # id -> Way
    relations: dict = field(default_factory=dict)    # id -> (tags, [(type, ref, role)])


@dataclass
class Edge:
    index: int
    way: int
    nodes: list          # node ids, in the way's drawing order
    length: float
    oneway: int          # 1: drawing order, -1: against it, 0: both
    name: str
    pit: bool
    alt: bool


@dataclass
class Loop:
    node_ids: list       # closed chain in driving order, first node not repeated
    names: list          # OSM way name per node ("" when unnamed)
    way_ids: list        # ways in driving order
    raw_length: float    # polyline length, metres (approximate projection)
    directed: bool       # True when the driving direction comes from oneway tags / way order
    candidates: list     # the best few cycles, for messages: (cost, length, [way ids])
    warnings: list = field(default_factory=list)


def parse(xml_bytes, into=None):
    data = into or OsmData()
    try:
        root = ET.fromstring(xml_bytes)
    except ET.ParseError as e:
        raise BuildError(f"OSM answer is not valid XML: {e}") from e
    for n in root.iter("node"):
        if n.get("lat") is None:
            continue
        data.nodes[n.get("id")] = (float(n.get("lat")), float(n.get("lon")))
        tags = {t.get("k"): t.get("v") for t in n.iter("tag")}
        if tags:
            data.node_tags[n.get("id")] = tags
    for w in root.iter("way"):
        tags = {t.get("k"): t.get("v") for t in w.iter("tag")}
        data.ways[int(w.get("id"))] = Way(int(w.get("id")), [x.get("ref") for x in w.iter("nd")], tags)
    for r in root.iter("relation"):
        tags = {t.get("k"): t.get("v") for t in r.iter("tag")}
        members = [(m.get("type"), m.get("ref"), m.get("role") or "") for m in r.iter("member")]
        data.relations[int(r.get("id"))] = (tags, members)
    return data


def _reduce_bbox_extract(xml_bytes):
    """Keeps only the raceway ways, their nodes, start / finish nodes and circuit relations
    of a bbox download, so the cache committed with a track stays small."""
    root = ET.fromstring(xml_bytes)
    keep_nodes, out = set(), ET.Element("osm", {k: v for k, v in root.attrib.items()})
    ways = []
    for w in root.iter("way"):
        if any(t.get("k") == "highway" and t.get("v") == "raceway" for t in w.iter("tag")):
            ways.append(w)
            keep_nodes.update(x.get("ref") for x in w.iter("nd"))
    way_ids = {w.get("id") for w in ways}
    for n in root.iter("node"):
        if n.get("id") in keep_nodes or any(t.get("k") == "raceway" for t in n.iter("tag")):
            out.append(n)
    out.extend(ways)
    for r in root.iter("relation"):
        if any(t.get("k") == "type" and t.get("v") == "circuit" for t in r.iter("tag")) and any(
                m.get("type") == "way" and m.get("ref") in way_ids for m in r.iter("member")):
            out.append(r)
    return ET.tostring(out, encoding="utf-8", xml_declaration=True)


def fetch(recipe, fetcher):
    """OsmData for the recipe's source (relation, way list or bounding box)."""
    data = OsmData()
    if recipe.osm_relation:
        url, name = f"{OSM_API}/relation/{recipe.osm_relation}/full", "osm_relation.xml"
        if (fetcher.cached(name) and not fetcher.offline
                and recipe.osm_relation not in parse(fetcher.read(name)).relations):
            # The cache is from another relation id (the recipe changed): fetch again.
            fetcher.write(name, fetcher.download(url))
        parse(fetcher.get(url, name), data)
        if recipe.osm_relation not in data.relations:
            raise BuildError(f"OSM relation {recipe.osm_relation} not found in the OSM data "
                             f"({fetcher.path(name)})")
    for wid in list(recipe.osm_ways) + list(recipe.extra_ways):
        if wid not in data.ways:
            parse(fetcher.get(f"{OSM_API}/way/{wid}/full", f"osm_way_{wid}.xml"), data)
    if recipe.osm_bbox and not recipe.osm_relation:
        w, s, e, n = recipe.osm_bbox
        key = hashlib.sha1(f"{w:.6f},{s:.6f},{e:.6f},{n:.6f}".encode()).hexdigest()[:8]
        name = f"osm_bbox_{key}.xml"      # one cache file per box, so a new box is fetched
        if not fetcher.cached(name):
            body = fetcher.download(f"{OSM_API}/map?bbox={w:.6f},{s:.6f},{e:.6f},{n:.6f}")
            fetcher.write(name, _reduce_bbox_extract(body))
        parse(fetcher.read(name), data)
    return data


def candidate_ways(data, recipe):
    """Ways the lap may use, and a note on where they came from."""
    excluded = set(recipe.exclude_ways)
    if recipe.osm_relation:
        _, members = data.relations[recipe.osm_relation]
        ids = [int(ref) for typ, ref, role in members
               if typ == "way" and not EXCLUDE_ROLE_RE.search(role)]
        source = f"relation {recipe.osm_relation}"
    else:
        ids = [w.id for w in data.ways.values() if w.tags.get("highway") == "raceway"]
        source = "raceway ways in the bounding box"
    # Ways the relation (or the raceway filter) lacks: the search cuts them at the nodes they
    # share with the other candidates, so a long road can lend just the piece the lap uses.
    ids += [wid for wid in recipe.extra_ways if wid not in ids]
    ways = []
    for wid in ids:
        w = data.ways.get(wid)
        if w is None or wid in excluded:
            continue
        nodes = [n for n in w.nodes if n in data.nodes]
        if len(nodes) >= 2:
            ways.append(Way(w.id, nodes, w.tags))
    return ways, source


class _Proj:
    """Local equirectangular projection (metres), good to ~0.1 % over a circuit."""
    def __init__(self, data, ways):
        lats = [data.nodes[n][0] for w in ways for n in w.nodes]
        self.kx = EARTH_M_PER_DEG * math.cos(math.radians(sum(lats) / len(lats)))
        self.data = data

    def xy(self, node):
        lat, lon = self.data.nodes[node]
        return (lon * self.kx, lat * EARTH_M_PER_DEG)

    def length(self, nodes):
        return sum(math.dist(self.xy(a), self.xy(b)) for a, b in zip(nodes, nodes[1:]))


def _oneway(tags):
    v = tags.get("oneway", "")
    return 1 if v in ("yes", "true", "1") else -1 if v in ("-1", "reverse") else 0


def _way_text(way):
    return " ".join(v for k, v in way.tags.items() if k == "name" or k.startswith("name:")
                    or k in ("service", "raceway", "description", "alt_name"))


def build_edges(ways, proj, recipe):
    """Splits the ways at shared nodes into graph edges."""
    use = {}
    for w in ways:
        for i, n in enumerate(w.nodes):
            use[n] = use.get(n, 0) + (1 if 0 < i < len(w.nodes) - 1 else 2)
    avoid = [a.lower() for a in recipe.avoid_names]
    # Two loops that differ only by which side of a junction they take cannot be told apart
    # by ways: [osm] avoid_nodes names a node of the wrong one, and no edge may touch it.
    blocked = {str(n) for n in recipe.avoid_nodes}
    edges = []
    for w in ways:
        text = _way_text(w)
        pit = bool(PIT_RE.search(text)) and not STRAIGHT_RE.search(w.name)
        alt = bool(ALT_RE.search(text)) or any(a in text.lower() for a in avoid)
        ow = 0 if recipe.ignore_oneway else _oneway(w.tags)
        start = 0
        for i in range(1, len(w.nodes)):
            # A node used again (by this way or another) is a junction: cut here.
            if i == len(w.nodes) - 1 or use[w.nodes[i]] > 1:
                seg = w.nodes[start:i + 1]
                if not blocked.intersection(seg):
                    edges.append(Edge(len(edges), w.id, seg, proj.length(seg), ow, w.name, pit, alt))
                start = i
    return edges


def _cycles(edges):
    """All simple cycles as lists of (edge, forward) arcs; each set of edges once."""
    arcs = {}
    for e in edges:
        a, b = e.nodes[0], e.nodes[-1]
        if e.oneway >= 0:
            arcs.setdefault(a, []).append((b, e.index, True))
        if e.oneway <= 0:
            arcs.setdefault(b, []).append((a, e.index, False))
    order = {n: i for i, n in enumerate(sorted(arcs))}
    found, seen, steps = [], set(), 0
    for root in sorted(arcs):
        # Cycles whose smallest node is `root`: only walk through larger nodes.
        stack = [(root, iter(arcs[root]))]
        path, on_path, used = [], {root}, set()
        while stack:
            node, it = stack[-1]
            for nxt, ei, fwd in it:
                steps += 1
                if steps > MAX_STEPS:
                    raise BuildError("the raceway graph is too tangled to search; narrow it down "
                                     "with [osm] exclude_ways or give [osm] ways explicitly")
                if ei in used or order.get(nxt, -1) < order[root]:
                    continue
                if nxt == root:
                    key = frozenset(used | {ei})
                    if key not in seen:
                        seen.add(key)
                        found.append(path + [(ei, fwd)])
                    continue
                if nxt in on_path or nxt not in arcs:
                    continue
                path.append((ei, fwd))
                used.add(ei)
                on_path.add(nxt)
                stack.append((nxt, iter(arcs[nxt])))
                break
            else:
                stack.pop()
                if path:
                    ei, _ = path.pop()
                    used.discard(ei)
                    on_path.discard(node)
    return found


def _describe_ways(ways, proj):
    lines = []
    for w in ways:
        extra = " ".join(f"{k}={w.tags[k]}" for k in ("oneway",) if k in w.tags)
        lines.append(f"    way {w.id:<11} {proj.length(w.nodes):8.1f} m  {w.name or '(unnamed)':<28} {extra}")
    return "\n".join(lines)


def _open_ends(edges, proj):
    """Dead-end nodes and the nearest other dead end: the usual sign of a gap in the data."""
    deg = {}
    for e in edges:
        for n in (e.nodes[0], e.nodes[-1]):
            deg[n] = deg.get(n, 0) + 1
    ends = [n for n, d in deg.items() if d == 1]
    lines = []
    for n in ends:
        others = [(math.dist(proj.xy(n), proj.xy(m)), m) for m in ends if m != n]
        if others:
            d, m = min(others)
            lines.append(f"    node {n} is a dead end; nearest other dead end {m} is {d:.1f} m away")
    return "\n".join(lines[:12])


def chain_explicit(ways_by_id, way_ids, proj):
    """Chains ``way_ids`` in the order given (reversing a way when it only fits backwards)."""
    chain, names = [], []
    for wid in way_ids:
        if wid not in ways_by_id:
            raise BuildError(f"recipe way {wid} was not found in the OSM data")
        w = ways_by_id[wid]
        ids = list(w.nodes)
        if chain:
            if ids[0] != chain[-1] and ids[-1] == chain[-1]:
                ids.reverse()
            if ids[0] != chain[-1]:
                raise BuildError(f"recipe way {wid} does not continue the chain: it does not "
                                 f"touch the end of the previous way (node {chain[-1]})")
            ids = ids[1:]
        elif len(way_ids) > 1:
            nxt = ways_by_id.get(way_ids[1])
            if nxt is not None and ids[-1] not in (nxt.nodes[0], nxt.nodes[-1]) and ids[0] in (nxt.nodes[0], nxt.nodes[-1]):
                ids.reverse()
        chain += ids
        names += [w.name] * len(ids)
    if chain[0] != chain[-1]:
        raise BuildError(f"the recipe's way list does not close: it starts at node {chain[0]} "
                         f"and ends at node {chain[-1]}")
    return Loop(chain[:-1], names[:-1], list(way_ids), proj.length(chain), True, [])


def find_loop(data, recipe, log=print):
    """The closed Grand Prix loop for ``recipe`` in ``data`` (see the module docstring)."""
    if recipe.osm_ways:
        ways = [w for w in data.ways.values()]
        proj = _Proj(data, [data.ways[w] for w in recipe.osm_ways if w in data.ways] or ways)
        return chain_explicit(data.ways, recipe.osm_ways, proj)
    ways, source = candidate_ways(data, recipe)
    if not ways:
        raise BuildError(f"no usable ways in {source}. Is it a type=circuit relation / are the "
                         "ways tagged highway=raceway? Otherwise list them: [osm] ways = [...]")
    proj = _Proj(data, ways)
    on_ways = {n for w in ways for n in w.nodes}
    for node in recipe.avoid_nodes:
        if str(node) not in on_ways:
            raise BuildError(f"recipe: osm.avoid_nodes: node {node} is not on any candidate way of {source}")
    edges = build_edges(ways, proj, recipe)
    cycles = _cycles(edges)
    warnings = []
    if not cycles and any(e.oneway for e in edges):
        for e in edges:
            e.oneway = 0
        cycles = _cycles(edges)
        if cycles:
            warnings.append("no closed loop follows the oneway tags; they were ignored, so the "
                            "driving direction needs [layout] direction in the recipe")
    listing = _describe_ways(ways, proj)
    gaps = _open_ends(edges, proj)
    gaps = f"  Gaps:\n{gaps}\n" if gaps else ""
    if not cycles:
        raise BuildError(
            f"the ways of {source} do not form a closed loop (official lap {recipe.length_m:.0f} m).\n"
            f"  Candidate ways:\n{listing}\n{gaps}"
            + "  Fix the data in OSM, or write the loop by hand: [osm] ways = [id, id, ...] in driving order.")

    scored = []
    for cyc in cycles:
        length = sum(edges[ei].length for ei, _ in cyc)
        pit = sum(edges[ei].length for ei, _ in cyc if edges[ei].pit) / length
        alt = any(edges[ei].alt for ei, _ in cyc)
        twoway = sum(edges[ei].length for ei, _ in cyc if edges[ei].oneway == 0) / length
        err = abs(length - recipe.length_m) / recipe.length_m
        # Prefer ways tagged oneway (the racing surface usually is) as a light tie-break.
        cost = err + PIT_PENALTY * pit + (ALT_PENALTY if alt else 0.0) + 0.002 * twoway
        scored.append((cost, err, length, cyc))
    scored.sort(key=lambda c: (c[0], c[2]))

    def way_list(cyc):
        out = []
        for ei, _ in cyc:
            if not out or out[-1] != edges[ei].way:
                out.append(edges[ei].way)
        if len(out) > 1 and out[0] == out[-1]:
            out.pop()
        return out

    cands = [(c[0], c[2], way_list(c[3])) for c in scored[:6]]
    cand_text = "\n".join(f"    {length:8.1f} m ({100 * (length / recipe.length_m - 1):+5.1f} %)  ways {wl}"
                          for _, length, wl in cands)
    cost, err, length, best = scored[0]
    if err > recipe.length_tolerance:
        raise BuildError(
            f"no loop in {source} matches the official lap length {recipe.length_m:.0f} m within "
            f"{100 * recipe.length_tolerance:.0f} %.\n  Closest loops:\n{cand_text}\n"
            f"  Candidate ways:\n{listing}\n{gaps}"
            "  If the best loop is the right one (OSM drawn long / short), raise [osm] "
            "length_tolerance; if a way is missing or wrong, use [osm] exclude_ways or list the "
            "loop by hand: [osm] ways = [id, id, ...] in driving order.")
    rivals = [c for c in scored[1:] if c[0] - cost < AMBIGUOUS and c[1] <= recipe.length_tolerance]
    if rivals:
        raise BuildError(
            f"{len(rivals) + 1} different loops in {source} match the official lap length "
            f"{recipe.length_m:.0f} m equally well, so the layout is ambiguous.\n"
            f"  Loops:\n{cand_text}\n  Candidate ways:\n{listing}\n"
            "  Drop the ways of the wrong layout with [osm] exclude_ways = [...] (or avoid_names), "
            "or list the loop by hand: [osm] ways = [id, id, ...] in driving order.")

    chain, names = [], []
    for ei, fwd in best:
        e = edges[ei]
        ids = e.nodes if fwd else e.nodes[::-1]
        chain += ids[1:]
        names += [e.name] * (len(ids) - 1)
    # Each junction node was appended by the edge that arrives at it; rotate so the chain
    # starts at the first edge's first node, like a hand-written way list would.
    chain, names = chain[-1:] + chain[:-1], names[-1:] + names[:-1]
    directed = all(edges[ei].oneway != 0 for ei, _ in best)
    if not directed and not recipe.direction:
        warnings.append("the loop's ways carry no oneway tags, so the driving direction is a guess; "
                        "set [layout] direction in the recipe")
    log(f"loop: {len(way_list(best))} ways, {length:.1f} m in OSM vs official {recipe.length_m:.0f} m "
        f"({100 * (length / recipe.length_m - 1):+.2f} %), picked from {len(cycles)} closed loop(s) in {source}")
    return Loop(chain, names, way_list(best), length, directed, cands, warnings)


def round_corners(data, loop, rounds, log=print):
    """Applies the recipe's ``[[osm.round]]`` entries to ``loop`` (in place).

    A circuit on public roads is drawn in OSM as the roads' centrelines, so where the lap
    turns at a junction the loop has one sharp vertex, however wide and fast the real corner
    is. Each entry replaces the loop from ``reach_m`` before its node to ``reach_m`` after it
    (measured along the loop) by a quadratic Bezier curve with the node as control point: a
    corner that begins and ends where the old loop was, with a minimum radius of about
    reach_m * cos^2(a / 2) / sin(a / 2) for a turn of angle a. The new points are added to
    ``data.nodes`` under made-up ids.
    """
    for k, spec in enumerate(rounds):
        node, reach = str(spec["node"]), float(spec["reach_m"])
        chain, names = loop.node_ids, loop.names
        n = len(chain)
        if node not in chain:
            raise BuildError(f"[[osm.round]] node {node} is not on the loop (or was removed by an "
                             "earlier [[osm.round]] entry)")
        i = chain.index(node)
        lat0, lon0 = data.nodes[node]
        kx, ky = EARTH_M_PER_DEG * math.cos(math.radians(lat0)), EARTH_M_PER_DEG

        def xy(m):
            lat, lon = data.nodes[m]
            return ((lon - lon0) * kx, (lat - lat0) * ky)

        def walk(step):
            """(index of the first node kept on this side, the point `reach` from the node)."""
            done, j = 0.0, i
            while True:
                nxt = (j + step) % n
                if nxt == i:
                    raise BuildError(f"[[osm.round]] node {node}: reach_m = {reach:g} is longer "
                                     "than the loop")
                a, b = xy(chain[j]), xy(chain[nxt])
                seg = math.dist(a, b)
                if done + seg >= reach:
                    t = (reach - done) / seg if seg > 0.0 else 1.0
                    return nxt, (a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t)
                done, j = done + seg, nxt

        ia, pa = walk(-1)
        ib, pb = walk(1)
        kept = (ia - ib) % n + 1          # nodes from ib on, round the loop, to ia
        if kept < 2 or (i - ib) % n < kept:
            raise BuildError(f"[[osm.round]] node {node}: reach_m = {reach:g} covers the whole loop")
        steps = max(4, int(math.ceil(2.0 * reach / 4.0)))
        ends = (xy(chain[ia]), xy(chain[ib]))
        new_ids = []
        for q in range(steps + 1):
            u = q / steps
            # Control point (0, 0): the node itself.
            p = ((1 - u) ** 2 * pa[0] + u ** 2 * pb[0], (1 - u) ** 2 * pa[1] + u ** 2 * pb[1])
            if min(math.dist(p, e) for e in ends) < 0.5:
                continue                  # (nearly) on a kept node: no double points
            nid = f"round{k}_{q}"
            data.nodes[nid] = (lat0 + p[1] / ky, lon0 + p[0] / kx)
            new_ids.append(nid)
        loop.node_ids = new_ids + [chain[(ib + q) % n] for q in range(kept)]
        loop.names = [names[i]] * len(new_ids) + [names[(ib + q) % n] for q in range(kept)]
        log(f"round: node {node} +/- {reach:g} m: {n - kept} loop nodes replaced by {len(new_ids)}")
    return loop


def start_finish_nodes(data, recipe, loop):
    """(finish (lat, lon) or None, start (lat, lon) or None, description of the source)."""
    on_loop = set(loop.node_ids)
    kx = EARTH_M_PER_DEG * math.cos(math.radians(data.nodes[loop.node_ids[0]][0]))

    def to_loop(node):
        lat, lon = data.nodes[node]
        return min(math.hypot((lon - data.nodes[m][1]) * kx, (lat - data.nodes[m][0]) * EARTH_M_PER_DEG)
                   for m in loop.node_ids)

    roles = {"start": [], "finish": []}
    if recipe.osm_relation and recipe.osm_relation in data.relations:
        for typ, ref, role in data.relations[recipe.osm_relation][1]:
            if typ == "node" and ref in data.nodes:
                for key in roles:
                    if role == key or role == "start_finish" or role == "start/finish":
                        roles[key].append(ref)
    tagged = {"start": [], "finish": []}
    for node, tags in data.node_tags.items():
        if node not in data.nodes:
            continue
        v = tags.get("raceway", "").lower()
        for key in tagged:
            if v == key or v in ("start_finish", "start/finish", "start_finish_line"):
                # Must sit on (or right at) the chosen loop: pit-lane lines do not count.
                if node in on_loop or to_loop(node) < 12.0:
                    tagged[key].append(node)
    src = {}
    picks = {}
    for key in ("finish", "start"):
        cands = roles[key] or tagged[key]
        if cands:
            picks[key] = cands
            src[key] = "relation member role" if roles[key] else "node tagged raceway=" + key
    out = {}
    for key in ("finish", "start"):
        cands = picks.get(key)
        if not cands:
            out[key] = None
            continue
        other = picks.get("start" if key == "finish" else "finish")
        if len(cands) > 1 and other:
            # Several lines (e.g. car and motorcycle): keep the one nearest the other line.
            o_lat, o_lon = data.nodes[other[0]]
            cands = sorted(cands, key=lambda n: math.hypot((data.nodes[n][1] - o_lon) * kx,
                                                          (data.nodes[n][0] - o_lat) * EARTH_M_PER_DEG))
        out[key] = data.nodes[cands[0]]
    desc = ", ".join(f"{k}: {v}" for k, v in src.items())
    return out["finish"], out["start"], desc

"""Shared paths for the track pipeline tests. Everything runs offline, on the caches committed
in assets/tracks/red_bull_ring/raw/.

    .venv/bin/python -m unittest discover tools/track/tests
"""
import json
import os
import sys

TESTS = os.path.dirname(os.path.abspath(__file__))
TRACK_TOOLS = os.path.dirname(TESTS)
ROOT = os.path.dirname(os.path.dirname(TRACK_TOOLS))
RBR = os.path.join(ROOT, "assets", "tracks", "red_bull_ring")
for p in (TRACK_TOOLS, os.path.join(ROOT, "cad", "track")):
    if p not in sys.path:
        sys.path.insert(0, p)

# The hand-written way list of the original fetch_red_bull_ring.py, in driving order.
RBR_LOOP_WAYS = [347958266, 822592398, 822592399, 822592400, 822592401, 822592402, 822592405,
                 822592406, 822592407, 822592408, 822592409, 822592410, 822592403, 822592404]
RBR_PIT_LANE = 289111668
RBR_MOTOGP_WAYS = [823820476, 1077423714]


def rbr_track():
    with open(os.path.join(RBR, "track.json"), encoding="utf-8") as f:
        return json.load(f)


def rbr_osm_xml():
    with open(os.path.join(RBR, "raw", "osm_relation.xml"), "rb") as f:
        return f.read()


def silent(*_args, **_kwargs):
    pass


def osm_xml(nodes, ways, relation=None, node_tags=None):
    """Tiny OSM XML document. nodes: {id: (lat, lon)}; ways: {id: (node ids, tags)};
    relation: (id, [(type, ref, role)]); node_tags: {id: tags}."""
    out = ['<osm version="0.6">']
    for nid, (lat, lon) in nodes.items():
        tags = "".join(f'<tag k="{k}" v="{v}"/>' for k, v in (node_tags or {}).get(nid, {}).items())
        out.append(f'<node id="{nid}" lat="{lat}" lon="{lon}">{tags}</node>')
    for wid, (nds, tags) in ways.items():
        out.append(f'<way id="{wid}">' + "".join(f'<nd ref="{n}"/>' for n in nds)
                   + "".join(f'<tag k="{k}" v="{v}"/>' for k, v in tags.items()) + "</way>")
    if relation:
        rid, members = relation
        out.append(f'<relation id="{rid}">' + "".join(f'<member type="{t}" ref="{r}" role="{role}"/>'
                                                       for t, r, role in members)
                   + '<tag k="type" v="circuit"/></relation>')
    out.append("</osm>")
    return "".join(out).encode()


def square_nodes(side_m=1000.0, lat0=47.0, lon0=14.0, per_side=5):
    """Nodes 1..4*per_side on a square of ``side_m``, clockwise from the north-west corner."""
    import math
    dlat = side_m / 111320.0
    dlon = side_m / (111320.0 * math.cos(math.radians(lat0)))
    corners = [(lat0, lon0), (lat0, lon0 + dlon), (lat0 - dlat, lon0 + dlon), (lat0 - dlat, lon0)]
    nodes, nid = {}, 1
    for c in range(4):
        a, b = corners[c], corners[(c + 1) % 4]
        for i in range(per_side):
            t = i / per_side
            nodes[nid] = (a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t)
            nid += 1
    return nodes

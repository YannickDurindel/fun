"""Scenery meshes (cad/track/scenery_glb.py): triangulation, extrusions, grandstands, tunnel
shells and the glb file.

    .venv/bin/python -m unittest tools/track/tests/test_surroundings_mesh.py
"""
import importlib.util
import json
import math
import struct
import tempfile
import unittest
from pathlib import Path

import helpers  # noqa: F401  (puts cad/track on the path)

HAVE_NUMPY = importlib.util.find_spec("numpy") is not None
if HAVE_NUMPY:
    import numpy as np
    import scenery_glb as sg


def square(x0, z0, size):
    return np.array([[x0, z0], [x0 + size, z0], [x0 + size, z0 + size], [x0, z0 + size]], dtype=float)


def soup(mesh, materials=None):
    """All triangles of a mesh as (positions (m, 3, 3), vertex normals (m, 3, 3), material names)."""
    tris, nrms, names = [], [], []
    for (i, j, material) in mesh.parts:
        if materials and material not in materials:
            continue
        pos, nrm, _, _, tri = mesh.arrays(i, j, material)
        tris.append(pos[tri].astype(float))
        nrms.append(nrm[tri].astype(float))
        names += [material] * len(tri)
    if not tris:
        return np.zeros((0, 3, 3)), np.zeros((0, 3, 3)), []
    return np.concatenate(tris), np.concatenate(nrms), names


def volume(tris):
    """Enclosed volume of outward-facing triangles (divergence theorem)."""
    return float(np.sum(np.einsum("ij,ij->i", tris[:, 0], np.cross(tris[:, 1], tris[:, 2]))) / 6.0)


def assert_normals_match_winding(test, tris, nrms):
    geo = np.cross(tris[:, 1] - tris[:, 0], tris[:, 2] - tris[:, 0])
    geo /= np.linalg.norm(geo, axis=1)[:, None]
    test.assertTrue(np.allclose(geo, nrms[:, 0], atol=1e-4), "a stored normal does not match the winding")


@unittest.skipUnless(HAVE_NUMPY, "the scenery meshes need numpy")
class TriangulationTest(unittest.TestCase):
    def area(self, pts, tri):
        a, b, c = pts[tri[:, 0]], pts[tri[:, 1]], pts[tri[:, 2]]
        cross = (b[:, 0] - a[:, 0]) * (c[:, 1] - a[:, 1]) - (b[:, 1] - a[:, 1]) * (c[:, 0] - a[:, 0])
        self.assertTrue((cross > 0.0).all(), "a triangle is flipped or flat")
        return float(np.sum(cross) * 0.5)

    def test_concave_ring(self):
        ell = np.array([[0, 0], [10, 0], [10, 4], [4, 4], [4, 10], [0, 10]], dtype=float)
        for ring in (ell, ell[::-1]):       # either orientation
            pts, tri = sg.triangulate(ring)
            self.assertEqual(len(tri), 4)
            self.assertAlmostEqual(self.area(pts, tri), 64.0)

    def test_ring_with_holes(self):
        outer = square(0, 0, 20)
        holes = [square(2, 2, 4), square(10, 3, 5), square(4, 12, 6)]
        pts, tri = sg.triangulate(outer, holes)
        self.assertAlmostEqual(self.area(pts, tri), 400.0 - 16.0 - 25.0 - 36.0)
        # No triangle covers the middle of a hole.
        for h in holes:
            c = h.mean(axis=0)
            a, b, d = pts[tri[:, 0]], pts[tri[:, 1]], pts[tri[:, 2]]
            inside = np.ones(len(tri), dtype=bool)
            for p, q in ((a, b), (b, d), (d, a)):
                inside &= (q[:, 0] - p[:, 0]) * (c[1] - p[:, 1]) - (q[:, 1] - p[:, 1]) * (c[0] - p[:, 0]) > 0.0
            self.assertFalse(inside.any())

    def test_star_and_circle_with_a_round_hole(self):
        ang = np.linspace(0.0, 2.0 * np.pi, 40, endpoint=False)
        rad = np.where(np.arange(40) % 2 == 0, 10.0, 4.0)
        star = np.stack([rad * np.cos(ang), rad * np.sin(ang)], axis=1)
        pts, tri = sg.triangulate(star)
        self.assertAlmostEqual(self.area(pts, tri), abs(sg.signed_area(star)), places=9)
        outer, hole = sg.ngon(0.0, 0.0, 30.0, 64), sg.ngon(5.0, 3.0, 8.0, 24)
        pts, tri = sg.triangulate(outer, [hole])
        self.assertAlmostEqual(self.area(pts, tri), abs(sg.signed_area(outer)) - abs(sg.signed_area(hole)), places=7)

    def test_repeated_and_collinear_points(self):
        ring = np.array([[0, 0], [5, 0], [5, 0], [10, 0], [10, 10], [5, 10], [0, 10], [0, 0]], dtype=float)
        pts, tri = sg.triangulate(ring)
        self.assertAlmostEqual(self.area(pts, tri), 100.0)

    def test_clip_halfplane(self):
        half = sg.clip_halfplane(square(0, 0, 10), 1.0, 0.0, -4.0)      # x >= 4
        self.assertAlmostEqual(abs(sg.signed_area(half)), 60.0)
        self.assertEqual(len(sg.clip_halfplane(square(0, 0, 10), 1.0, 0.0, -40.0)), 0)


@unittest.skipUnless(HAVE_NUMPY, "the scenery meshes need numpy")
class ExtrusionTest(unittest.TestCase):
    def test_prism_is_closed_and_faces_outward(self):
        ell = np.array([[0, 0], [10, 0], [10, 4], [4, 4], [4, 10], [0, 10]], dtype=float)
        for ring in (ell, ell[::-1]):
            mesh = sg.SceneryMesh()
            mesh.anchor(5.0, 5.0)
            sg.prism(mesh, ring, [], 2.0, 9.0, "building_wall", "building_roof", (1, 1, 1, 1), (1, 1, 1, 0), 3.0,
                     floor=True)
            tris, nrms, names = soup(mesh)
            assert_normals_match_winding(self, tris, nrms)
            self.assertAlmostEqual(volume(tris), 64.0 * 7.0, places=3)
            # Closed: the area-weighted normals of a closed surface add up to nothing.
            total = np.sum(np.cross(tris[:, 1] - tris[:, 0], tris[:, 2] - tris[:, 0]), axis=0)
            self.assertTrue(np.allclose(total, 0.0, atol=1e-3))
            self.assertEqual(names.count("building_roof"), 4)
            roof = [t for t, n in zip(nrms, names) if n == "building_roof"]
            self.assertTrue(all(t[0][1] == 1.0 for t in roof))

    def test_courtyard_walls_face_the_courtyard(self):
        mesh = sg.SceneryMesh()
        mesh.anchor(10.0, 10.0)
        sg.prism(mesh, square(0, 0, 20), [square(8, 8, 4)], 0.0, 6.0, "building_wall", "building_roof",
                 (1, 1, 1, 1), (1, 1, 1, 0), 0.0, floor=True)
        tris, nrms, _ = soup(mesh)
        assert_normals_match_winding(self, tris, nrms)
        self.assertAlmostEqual(volume(tris), (400.0 - 16.0) * 6.0, places=3)
        inner = [(t.mean(axis=0), n[0]) for t, n in zip(tris, nrms)
                 if abs(n[0][1]) < 0.5 and 7.9 < t[:, 0].min() and t[:, 0].max() < 12.1]
        self.assertEqual(len(inner), 8)
        for c, n in inner:
            self.assertGreater(float(np.dot(np.array([10.0, c[1], 10.0]) - c, n)), 0.0)

    def test_wall_uv_is_metres_and_colour_is_the_building_tint(self):
        mesh = sg.SceneryMesh()
        mesh.anchor(0.0, 0.0)
        sg.prism(mesh, square(0, 0, 10), [], -1.5, 12.0, "building_wall", "building_roof", (0.5, 0.25, 1.0, 1.0),
                 (0.2, 0.2, 0.2, 0.0), 0.0)
        pos, _, uv, col, _ = mesh.arrays(0, 0, "building_wall")
        self.assertEqual(len(pos), 16)                              # four walls, four corners each
        self.assertTrue(np.allclose(uv[:, 1], pos[:, 1]))           # v = height above the ground line
        self.assertAlmostEqual(float(uv[:, 1].min()), -1.5)         # the plinth is below zero
        self.assertAlmostEqual(float(uv[:, 0].min()), 0.0)
        self.assertAlmostEqual(float(uv[:, 0].max()), 10.0)         # u starts again at every corner
        self.assertTrue((col == [128, 64, 255, 255]).all())
        _, _, ruv, rcol, _ = mesh.arrays(0, 0, "building_roof")
        self.assertTrue((rcol[:, 3] == 0).all())
        self.assertAlmostEqual(float(ruv.max()), 10.0)

    def test_u_runs_on_round_a_curved_wall(self):
        mesh = sg.SceneryMesh()
        mesh.anchor(0.0, 0.0)
        ring = sg.ngon(0.0, 0.0, 10.0, 36)
        sg.wall_quads(mesh, "building_wall", ring, 0.0, 5.0, (1, 1, 1, 1), 0.0)
        _, _, uv, _, _ = mesh.arrays(0, 0, "building_wall")
        self.assertAlmostEqual(float(uv[:, 0].max()), 36 * 2 * 10.0 * math.sin(math.pi / 36), places=3)

    def test_gabled_roof(self):
        mesh = sg.SceneryMesh()
        mesh.anchor(0.0, 0.0)
        ring = np.array([[0, 0], [12, 0], [12, 8], [0, 8]], dtype=float)
        sg.wall_quads(mesh, "building_wall", ring, 0.0, 5.0, (1, 1, 1, 1), 0.0)
        sg.gabled_roof(mesh, ring, 5.0, 3.0, "building_wall", "building_roof", (1, 1, 1, 1), (1, 1, 1, 0), 0.0)
        tris, nrms, names = soup(mesh)
        assert_normals_match_winding(self, tris, nrms)
        # Open underneath at y = 0, where the missing floor adds nothing to the integral.
        self.assertAlmostEqual(volume(tris), 12 * 8 * 5.0 + 0.5 * 8 * 3.0 * 12, places=3)
        roof = np.array([t for t, n in zip(tris, names) if n == "building_roof"])
        ridge = roof[roof[:, :, 1] > 7.9]
        self.assertTrue(np.allclose(ridge[:, 2], 4.0))          # along the long side, in the middle
        self.assertTrue(all(n[0][1] > 0.5 for n, m in zip(nrms, names) if m == "building_roof"))

    def test_ribbon_and_box_are_closed(self):
        mesh = sg.SceneryMesh()
        mesh.anchor(0.0, 0.0)
        centre = np.array([[0.0, 5.0, 0.0], [10.0, 5.0, 0.0], [20.0, 6.0, 0.0]])
        right = np.array([[0.0, 1.0]] * 3)
        sg.ribbon(mesh, "concrete", centre, right, 8.0, 1.0, (1, 1, 1, 0))
        tris, nrms, _ = soup(mesh)
        assert_normals_match_winding(self, tris, nrms)
        self.assertAlmostEqual(volume(tris), 20.0 * 8.0 * 1.0, places=3)
        mesh = sg.SceneryMesh()
        sg.box(mesh, "metal", (1.0, 2.0, 3.0), (2.0, 5.0, 7.0), (1, 1, 1, 0))
        tris, nrms, _ = soup(mesh)
        assert_normals_match_winding(self, tris, nrms)
        self.assertAlmostEqual(volume(tris), 12.0, places=4)


@unittest.skipUnless(HAVE_NUMPY, "the scenery meshes need numpy")
class GrandstandTest(unittest.TestCase):
    def build(self, toward, covered=False, height=None):
        mesh = sg.SceneryMesh()
        mesh.anchor(0.0, 0.0)
        ring = np.array([[0, 0], [40, 0], [40, 12], [0, 12]], dtype=float)
        rows, top = sg.grandstand(mesh, ring, np.array(toward, dtype=float), 100.0, 98.5, height,
                                  (0.3, 0.4, 0.6, 0.0), covered)
        return mesh, rows, top

    def test_rows_rise_away_from_the_track(self):
        for toward, axis, sign in (((0.0, -1.0), 2, 1.0), ((0.0, 1.0), 2, -1.0)):
            mesh, rows, top = self.build(toward)
            self.assertEqual(rows, 14)
            self.assertAlmostEqual(top, 1.2 + 0.5 * 12.0)
            tris, nrms, names = soup(mesh, {"stand_seats"})
            assert_normals_match_winding(self, tris, nrms)
            treads = np.array([t for t, n in zip(tris, nrms) if n[0][1] > 0.9])
            depth = treads[:, :, axis].mean(axis=1) * sign
            height = treads[:, :, 1].mean(axis=1)
            order = np.argsort(depth)
            self.assertTrue((np.diff(height[order]) >= -1e-6).all())
            self.assertAlmostEqual(float(height.min()), 100.0 + 1.2, places=4)
            self.assertAlmostEqual(float(height.max()), 100.0 + top, places=4)
            # The risers look at the track.
            risers = np.array([n[0] for n in nrms if abs(n[0][1]) < 0.1])
            self.assertEqual(len(risers), 2 * (rows - 1))
            self.assertTrue(np.allclose(risers[:, [0, 2]], toward))
            # Treads cover the footprint exactly once.
            area = 0.5 * np.linalg.norm(np.cross(treads[:, 1] - treads[:, 0], treads[:, 2] - treads[:, 0]), axis=1)
            self.assertAlmostEqual(float(area.sum()), 480.0, places=3)

    def test_structure_reaches_into_the_ground_and_seat_uv_counts_rows(self):
        mesh, rows, _ = self.build((0.0, -1.0))
        pos, _, _, col, _ = mesh.arrays(0, 0, "stand_structure")
        self.assertAlmostEqual(float(pos[:, 1].min()), 98.5)
        self.assertTrue((col[:, 3] == 0).all())
        _, nrm, uv, _, _ = mesh.arrays(0, 0, "stand_seats")
        flat = nrm[:, 1] > 0.9
        self.assertAlmostEqual(float(uv[flat, 0].max()), 40.0, places=4)   # u along the row
        self.assertAlmostEqual(float(uv[flat, 1].max()), 12.0, places=4)   # v = depth from the front

    def test_height_from_the_map_and_a_roof_when_covered(self):
        mesh, _, top = self.build((0.0, -1.0), covered=True, height=15.0)
        self.assertEqual(top, 15.0)
        pos, _, _, _, _ = mesh.arrays(0, 0, "metal")
        self.assertAlmostEqual(float(pos[:, 1].min()), 100.0 + 15.0 + 4.0)

    def test_the_axis_follows_the_footprint_not_the_exact_bearing(self):
        ring = np.array([[0, 0], [40, 0], [40, 12], [0, 12]], dtype=float)
        back = sg.stand_axis(ring, np.array([0.3, -0.95]))
        self.assertTrue(np.allclose(back, [0.0, 1.0]))


@unittest.skipUnless(HAVE_NUMPY, "the scenery meshes need numpy")
class RoofShellTest(unittest.TestCase):
    def shell(self, kind):
        mesh = sg.SceneryMesh()
        mesh.anchor(0.0, 0.0)
        n = 21
        centre = np.stack([np.linspace(0.0, 100.0, n), np.linspace(10.0, 15.0, n), np.zeros(n)], axis=1)
        right = np.array([[0.0, 1.0]] * n)
        lights = sg.roof_shell(mesh, centre, right, np.full(n, 7.0), centre[:, 1], centre[:, 1], 5.5, kind)
        return mesh, lights

    def test_tunnel_has_walls_a_ceiling_that_follows_the_road_and_lights(self):
        mesh, lights = self.shell("tunnel")
        tris, nrms, _ = soup(mesh, {"concrete"})
        assert_normals_match_winding(self, tris, nrms)
        centres, normals = tris.mean(axis=1), nrms[:, 0]
        inner = np.abs(centres[:, 2]) < 7.01
        ceiling = inner & (normals[:, 1] < -0.9)
        self.assertEqual(int(ceiling.sum()), 2 * 20)
        road_y = 10.0 + centres[ceiling, 0] * 0.05
        self.assertTrue(np.allclose(centres[ceiling, 1] - road_y, 5.5, atol=0.1))      # clear height
        # Inner wall faces look at the road, and nothing of the shell is inside the tube.
        walls = (np.abs(np.abs(centres[:, 2]) - 7.0) < 1e-6) & (np.abs(normals[:, 1]) < 0.1) & (np.abs(normals[:, 2]) > 0.9)
        self.assertEqual(int(walls.sum()), 2 * 2 * 20)
        self.assertTrue((np.sign(normals[walls, 2]) == -np.sign(centres[walls, 2])).all())
        y_rel = tris[:, :, 1] - (10.0 + tris[:, :, 0] * 0.05)
        in_tube = (np.abs(tris[:, :, 2]) < 6.99) & (y_rel > 0.01) & (y_rel < 5.49)
        self.assertFalse(in_tube.any())
        self.assertTrue((tris[:, :, 1] - (10.0 + tris[:, :, 0] * 0.05) > -0.61).all())  # feet just under the road
        self.assertEqual(lights, 2 * 12)
        ltris, lnrms, _ = soup(mesh, {"emissive_light"})
        self.assertEqual(len(ltris), 2 * lights)
        self.assertTrue((lnrms[:, 0, 1] < -0.9).all())

    def test_tunnel_shell_is_a_closed_solid(self):
        # A level road 0.6 m up puts the open feet of the walls at y = 0, where the missing
        # faces add nothing to the volume integral: walls and slab, 0.8 m thick.
        mesh = sg.SceneryMesh()
        n = 11
        centre = np.stack([np.linspace(0.0, 100.0, n), np.full(n, 0.6), np.zeros(n)], axis=1)
        sg.roof_shell(mesh, centre, np.array([[0.0, 1.0]] * n), np.full(n, 7.0), centre[:, 1], centre[:, 1], 5.5)
        tris, nrms, _ = soup(mesh, {"concrete"})
        assert_normals_match_winding(self, tris, nrms)
        self.assertAlmostEqual(volume(tris), 100.0 * (15.6 * 6.9 - 14.0 * 6.1), delta=0.5)

    def test_open_sides_stand_on_columns(self):
        tunnel = len(soup(self.shell("tunnel")[0], {"concrete"})[0])
        for kind, open_side in (("gallery_right", 1.0), ("gallery_left", -1.0)):
            mesh, lights = self.shell(kind)
            tris, nrms, _ = soup(mesh, {"concrete"})
            assert_normals_match_winding(self, tris, nrms)
            self.assertGreater(lights, 0)
            c = tris.mean(axis=1)
            long_wall = (np.abs(nrms[:, 0, 2]) > 0.9) & (c[:, 2] * open_side > 6.9) & (c[:, 1] < 15.4 + c[:, 0] * 0.05)
            # Only column faces on the open side: 13 columns, 2 faces across each, 2 triangles a face.
            self.assertEqual(int(long_wall.sum()), 13 * 2 * 2)
        mesh, lights = self.shell("overpass")
        self.assertEqual(lights, 0)
        self.assertLess(len(soup(mesh, {"concrete"})[0]), tunnel)

    def test_pieces_of_a_long_shell_have_no_face_between_them(self):
        mesh = sg.SceneryMesh()
        n = 5
        centre = np.stack([np.linspace(0.0, 20.0, n), np.zeros(n), np.zeros(n)], axis=1)
        right = np.array([[0.0, 1.0]] * n)
        sg.roof_shell(mesh, centre, right, np.full(n, 7.0), np.zeros(n), np.zeros(n), 5.5, "tunnel",
                      portals=(True, False))
        tris, nrms, _ = soup(mesh, {"concrete"})
        along = np.abs(nrms[:, 0, 0]) > 0.9
        self.assertTrue((tris[along][:, :, 0] < 1e-6).all())


@unittest.skipUnless(HAVE_NUMPY, "the scenery meshes need numpy")
class GlbTest(unittest.TestCase):
    def read(self, path):
        raw = Path(path).read_bytes()
        magic, version, total = struct.unpack_from("<III", raw, 0)
        self.assertEqual((magic, version, total), (0x46546C67, 2, len(raw)))
        jlen = struct.unpack_from("<I", raw, 12)[0]
        return json.loads(raw[20:20 + jlen]), raw[20 + jlen + 8:]

    def test_chunks_materials_and_vertex_colours(self):
        mesh = sg.SceneryMesh(-800.0, -800.0)
        for x, z in ((10.0, 10.0), (450.0, 10.0), (-790.0, -10.0)):
            mesh.anchor(x, z)
            sg.prism(mesh, square(x, z, 10), [], 0.0, 8.0, "building_wall", "building_roof", (1.0, 0.5, 0.0, 1.0),
                     (0.5, 0.5, 0.5, 0.0), 0.0)
        mesh.anchor(10.0, 10.0)
        sg.box(mesh, "emissive_light", (0, 0, 0), (1, 1, 1), (1, 1, 1, 0))
        with tempfile.TemporaryDirectory() as d:
            stats = sg.write_glb(Path(d) / "scenery.glb", mesh, "test", "unit test")
            gltf, blob = self.read(Path(d) / "scenery.glb")
        self.assertEqual([n["name"] for n in gltf["nodes"]], ["chunk_0_1", "chunk_2_2", "chunk_3_2"])
        self.assertEqual([m["name"] for m in gltf["materials"]], ["building_wall", "building_roof", "emissive_light"])
        self.assertEqual(stats["triangles"], 3 * 10 + 12)
        self.assertEqual(sum(mesh.triangle_counts().values()), stats["triangles"])
        prims = gltf["meshes"][1]["primitives"]
        self.assertEqual(len(prims), 3)             # one primitive per material in the chunk
        for p in prims:
            self.assertEqual(sorted(p["attributes"]), ["COLOR_0", "NORMAL", "POSITION", "TEXCOORD_0"])
            col = gltf["accessors"][p["attributes"]["COLOR_0"]]
            self.assertEqual((col["componentType"], col["type"], col.get("normalized")), (5121, "VEC4", True))
            self.assertEqual(gltf["accessors"][p["indices"]]["componentType"], 5123)    # uint16
            for acc in (gltf["accessors"][a] for a in list(p["attributes"].values()) + [p["indices"]]):
                view = gltf["bufferViews"][acc["bufferView"]]
                self.assertEqual(view["byteOffset"] % 4, 0)
                self.assertLessEqual(view["byteOffset"] + view["byteLength"], len(blob))
        wall = gltf["accessors"][prims[0]["attributes"]["COLOR_0"]]
        view = gltf["bufferViews"][wall["bufferView"]]
        self.assertEqual(tuple(blob[view["byteOffset"]:view["byteOffset"] + 4]), (255, 128, 0, 255))
        pos = gltf["accessors"][prims[0]["attributes"]["POSITION"]]
        self.assertEqual(pos["min"], [10.0, 0.0, 10.0])
        self.assertEqual(pos["max"], [20.0, 8.0, 20.0])

    def test_large_primitives_use_uint32_and_an_empty_scene_is_valid(self):
        mesh = sg.SceneryMesh()
        mesh.anchor(0.0, 0.0)
        ring = sg.ngon(0.0, 0.0, 50.0, 400)
        for k in range(42):
            sg.wall_quads(mesh, "concrete", ring, float(k), k + 1.0, (1, 1, 1, 0), 0.0)
        with tempfile.TemporaryDirectory() as d:
            sg.write_glb(Path(d) / "big.glb", mesh, "test", "unit test")
            gltf, _ = self.read(Path(d) / "big.glb")
            prim = gltf["meshes"][0]["primitives"][0]
            self.assertEqual(gltf["accessors"][prim["indices"]]["componentType"], 5125)
            stats = sg.write_glb(Path(d) / "empty.glb", sg.SceneryMesh(), "test", "unit test")
            gltf, _ = self.read(Path(d) / "empty.glb")
        self.assertEqual(stats["triangles"], 0)
        self.assertNotIn("meshes", gltf)


if __name__ == "__main__":
    unittest.main()

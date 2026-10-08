"""Recipe parsing: defaults from calendar.json, the Red Bull Ring recipe, and error messages."""
import os
import tempfile
import unittest

import helpers  # noqa: F401  (sets sys.path)
from lib import recipe
from lib.net import BuildError


class RecipeTest(unittest.TestCase):
    def test_red_bull_ring_recipe(self):
        r = recipe.load("red_bull_ring")
        self.assertEqual(r.osm_relation, 5309181)
        self.assertEqual(r.length_m, 4318.0)
        self.assertEqual(r.turns, 10)
        self.assertEqual(r.direction, "clockwise")
        self.assertEqual(r.spline, "uniform")
        self.assertEqual(r.sectors, [2352.2, 3219.5])
        self.assertTrue(r.turns_pinned)
        self.assertEqual([t["id"] for t in r.turn_table], [f"T{i}" for i in range(1, 11)])
        self.assertEqual(r.turn_table[2]["name"], "Remus")
        self.assertEqual(len(r.road["bank_keys"]), 29)
        self.assertEqual(len(r.road["width_keys"]), 20)
        self.assertEqual(r.terrain["near"], [-1600.0, 800.0, -1200.0, 600.0])
        # Not in the recipe: filled in from assets/tracks/calendar.json.
        self.assertEqual(r.name, "Red Bull Ring")
        self.assertEqual(r.country_code, "AT")
        self.assertEqual(r.full_name, "Red Bull Ring (Grand Prix circuit)")
        self.assertEqual(r.source, os.path.join("tools", "track", "tracks", "red_bull_ring.toml"))

    def test_no_recipe_file_uses_calendar_and_command_line(self):
        # A calendar circuit built without a recipe file. Every circuit of the calendar has one
        # by now, so the empty recipe is given directly (load() does the same for a missing file).
        r = recipe.from_dict("monaco", {}, overrides={"osm_relation": 9291096, "name": None})
        self.assertEqual((r.length_m, r.turns, r.country_code), (3337.0, 19, "MC"))
        self.assertEqual(r.osm_relation, 9291096)
        self.assertFalse(r.turns_pinned)
        self.assertEqual(r.spline, "centripetal")
        self.assertEqual(r.road, {})
        self.assertEqual(r.source, "")
        # load() with no recipe file for the id: the same empty recipe.
        r = recipe.load("no_such_circuit", overrides={"osm_relation": 1, "length_m": 4000.0})
        self.assertEqual((r.length_m, r.source, r.road, r.turn_table), (4000.0, "", {}, []))

    def test_command_line_overrides_recipe(self):
        r = recipe.from_dict("red_bull_ring", {"length_m": 4000, "osm": {"relation": 1}},
                             {"length_m": 4318.0, "direction": "anticlockwise"})
        self.assertEqual(r.length_m, 4318.0)
        self.assertEqual(r.direction, "anticlockwise")

    def test_track_outside_the_calendar_needs_a_length(self):
        with self.assertRaisesRegex(BuildError, "official lap length"):
            recipe.from_dict("my_kart_track", {"osm": {"relation": 5}})
        r = recipe.from_dict("my_kart_track", {"osm": {"relation": 5}, "length_m": 1200})
        self.assertEqual(r.name, "My Kart Track")
        self.assertIsNone(r.turns)

    def test_missing_osm_source(self):
        with self.assertRaisesRegex(BuildError, "no OSM source"):
            recipe.from_dict("imola", {})

    def test_unknown_keys_are_rejected(self):
        with self.assertRaisesRegex(BuildError, "unknown key.*lenght_m"):
            recipe.from_dict("imola", {"lenght_m": 4909, "osm": {"relation": 1}})
        with self.assertRaisesRegex(BuildError, r"unknown key.*\[osm\]"):
            recipe.from_dict("imola", {"osm": {"relation": 1, "relaton": 2}})

    def test_bad_values(self):
        base = {"osm": {"relation": 1}}
        for extra, pattern in (
                ({"layout": {"direction": "left"}}, "direction"),
                ({"layout": {"finish": [200.0, 3.0]}}, "lat, lon"),
                ({"layout": {"sectors": [3000.0, 1000.0]}}, "sectors"),
                ({"layout": {"spline": "bezier"}}, "spline"),
                ({"osm": {"bbox": [2.0, 1.0, 1.0, 2.0]}}, "bbox"),
                ({"turn": [{"name": "x"}]}, "needs an id"),
                ({"turn": [{"id": "T1", "s": 10.0, "direction": "left"}, {"id": "T2"}]}, "either every"),
                ({"turn": [{"id": "T1", "s": 500.0, "direction": "left"},
                           {"id": "T2", "s": 100.0, "direction": "left"}]}, "lap order"),
                ({"road": {"bank_keys": [[100.0, 0.01], [50.0, 0.02]]}}, "bank_keys"),
                ({"road": {"override": [{"s": [0, 100]}]}}, "width and/or bank"),
                ({"road": {"crossfall": 1.5}}, "road.crossfall"),
                ({"terrain": {"near": [0, -100, 0, 100]}}, "terrain.near"),
                ({"terrain": {"smooth_sigma_m": -1.0}}, "terrain.smooth_sigma_m")):
            with self.subTest(extra=extra), self.assertRaisesRegex(BuildError, pattern):
                recipe.from_dict("imola", {**base, **extra})

    def test_osm_round(self):
        base = {"osm": {"relation": 1}}
        r = recipe.from_dict("imola", {"osm": {"relation": 1, "round": [
            {"node": 42, "reach_m": 30.0, "note": "Turn 1"}]}})
        self.assertEqual(r.osm_round, [{"node": 42, "reach_m": 30.0, "note": "Turn 1"}])
        self.assertEqual(recipe.from_dict("imola", base).osm_round, [])
        for bad, pattern in (({"node": 42, "reach_m": 30.0, "raech": 1}, "unknown key"),
                             ({"node": "42", "reach_m": 30.0}, "needs node"),
                             ({"node": 42, "reach_m": 0.5}, "needs node"),
                             ({"node": 42}, "needs node")):
            with self.subTest(bad=bad), self.assertRaisesRegex(BuildError, pattern):
                recipe.from_dict("imola", {"osm": {"relation": 1, "round": [bad]}})

    def test_id_mismatch_and_bad_id(self):
        with self.assertRaisesRegex(BuildError, "does not match"):
            recipe.from_dict("imola", {"id": "monza", "osm": {"relation": 1}})
        with self.assertRaisesRegex(BuildError, "lower-case"):
            recipe.from_dict("Imola GP", {"osm": {"relation": 1}})

    def test_names_only_turn_table_is_not_pinned(self):
        r = recipe.from_dict("imola", {"osm": {"relation": 1}, "turn": [{"id": "T7", "name": "Tosa"}]})
        self.assertFalse(r.turns_pinned)

    def test_invalid_toml_and_missing_file(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "x.toml")
            with open(path, "w") as f:
                f.write("length_m = = 3\n")
            with self.assertRaisesRegex(BuildError, "not valid TOML"):
                recipe.load("imola", path)
            with self.assertRaisesRegex(BuildError, "cannot read recipe"):
                recipe.load("imola", os.path.join(d, "missing.toml"))


if __name__ == "__main__":
    unittest.main()

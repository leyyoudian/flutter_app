import unittest
from pathlib import Path
import sys
import json
import tempfile
import zipfile
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import encode_factory


class ThirdHalfTransitionTests(unittest.TestCase):
    def test_factory_zoom_overrides_match_pre_scaled_materials(self):
        for eid in ("F003", "F006", "F007", "F018"):
            self.assertEqual(encode_factory.get_zoom(eid), 1.0)
        self.assertEqual(encode_factory.get_zoom("F008"), 1.3)
        self.assertEqual(encode_factory.get_zoom("F001"), 1.1)

    def test_third_half_transitions_are_never_zoomed(self):
        for eid in ("F006", "F007", "F008_F009"):
            self.assertEqual(encode_factory.get_third_zoom(eid), 1.0)

    def test_f006_f007_bare_names_are_target_named_mutual_transitions(self):
        self.assertEqual(encode_factory.third_transition_pairs("F006"), [("F007", "F006")])
        self.assertEqual(encode_factory.third_transition_pairs("F007"), [("F006", "F007")])

    def test_other_bare_names_do_not_create_special_transitions(self):
        self.assertEqual(encode_factory.third_transition_pairs("F005"), [])
        self.assertEqual(encode_factory.third_transition_pairs("F008"), [])

    def test_explicit_source_destination_names_still_work(self):
        self.assertEqual(encode_factory.third_transition_pairs("F007_F006"), [("F007", "F006")])

    def test_main_keeps_factory_pairs_after_building_third_map(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            with patch.object(encode_factory, "ROOT", root), \
                 patch.object(encode_factory, "OUT_DIR", root / "animation_sd"), \
                 patch.object(encode_factory, "find_pairs", return_value=[
                     ("F001", Path("1.mp4"), Path("1_exit.mp4")),
                 ]), \
                 patch.object(encode_factory, "find_third", return_value=[
                     ("F006", Path("F006.mp4")),
                 ]), \
                 patch.object(encode_factory, "discover_factory_loop_sources", return_value=[]), \
                 patch.object(encode_factory, "process"), \
                 patch.object(encode_factory, "preview"), \
                 patch.object(encode_factory, "make_dial_mp4"):
                encode_factory.main()

            manifest_path = root / "app_gif" / "assets" / "factory_previews" / "manifest.json"
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            self.assertEqual([entry["id"] for entry in manifest], ["F001"])
            self.assertEqual(manifest[0]["transitions"], {})

    def test_factory_loop_source_names_normalize_to_f_ids(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            loop_dir = root / "factory_loop"
            loop_dir.mkdir()
            (loop_dir / "22.mp4").write_bytes(b"fake")
            (loop_dir / "F023.mp4").write_bytes(b"fake")

            found = encode_factory.discover_factory_loop_sources(root)

            self.assertEqual(
                [(item_id, path.name) for item_id, path in found],
                [("F022", "22.mp4"), ("F023", "F023.mp4")],
            )

    def test_f022_plus_third_half_sources_are_factory_loops(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            third_dir = root / "third_half"
            third_dir.mkdir()
            (third_dir / "F022.mp4").write_bytes(b"fake")
            (third_dir / "F023.mp4").write_bytes(b"fake")
            (third_dir / "F007.mp4").write_bytes(b"fake")

            found = encode_factory.discover_factory_loop_sources(root)

            self.assertEqual(
                [(item_id, path.name) for item_id, path in found],
                [("F022", "F022.mp4"), ("F023", "F023.mp4")],
            )
            with patch.object(encode_factory, "SRC_DIR", root):
                self.assertEqual(encode_factory.find_third(), [("F007", third_dir / "F007.mp4")])

    def test_factory_import_zip_contains_loop_candidate_manifests(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            app_dir = root / "app"
            device_dir = root / "device" / "factory_loop"
            app_dir.mkdir(parents=True)
            device_dir.mkdir(parents=True)
            (app_dir / "F022.png").write_bytes(b"png")
            (app_dir / "F022_loop.mp4").write_bytes(b"mp4")
            (device_dir / "F022.eb4").write_bytes(b"eb4")
            zip_path = root / "factory-import.zip"

            encode_factory.write_factory_import_zip([
                {
                    "id": "F022",
                    "title": "F022",
                    "type": "loop",
                    "protected": False,
                    "minFirmwareVersion": "0.1.44",
                    "thumbnail": app_dir / "F022.png",
                    "loopVideo": app_dir / "F022_loop.mp4",
                    "deviceFiles": [
                        {
                            "path": "factory_loop/F022.eb4",
                            "source": device_dir / "F022.eb4",
                        },
                    ],
                },
            ], zip_path)

            with zipfile.ZipFile(zip_path) as zf:
                names = set(zf.namelist())
                self.assertIn("import.json", names)
                self.assertIn("items/F022/manifest.json", names)
                self.assertIn("items/F022/app/F022.png", names)
                self.assertIn("items/F022/app/F022_loop.mp4", names)
                self.assertIn("items/F022/device/factory_loop/F022.eb4", names)
                import_manifest = json.loads(zf.read("import.json").decode("utf-8"))
                item_manifest = json.loads(zf.read("items/F022/manifest.json").decode("utf-8"))

            self.assertEqual(import_manifest["items"], ["items/F022/manifest.json"])
            self.assertEqual(item_manifest["id"], "F022")
            self.assertEqual(item_manifest["type"], "loop")
            self.assertEqual(item_manifest["appFiles"]["loopVideo"], "app/F022_loop.mp4")
            self.assertEqual(item_manifest["deviceFiles"][0]["path"], "factory_loop/F022.eb4")


if __name__ == "__main__":
    unittest.main()

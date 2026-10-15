from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from ios_ci_version import build_version


class BuildVersionTest(unittest.TestCase):
    def test_cli_does_not_export_flutter_reserved_version_variables(self):
        script = Path(__file__).with_name("ios_ci_version.py")
        with tempfile.TemporaryDirectory() as directory:
            pubspec = Path(directory) / "pubspec.yaml"
            pubspec.write_text("version: 1.0.31+33\n", encoding="utf-8")
            result = subprocess.run(
                [
                    sys.executable, str(script), "--pubspec", str(pubspec),
                    "--project-build-number", "44",
                ],
                check=True,
                capture_output=True,
                text=True,
            )
        exports = dict(line.split("=", 1) for line in result.stdout.splitlines())
        self.assertTrue(exports)
        self.assertFalse(any(key.startswith("FLUTTER_") for key in exports))
        self.assertEqual(
            exports,
            {"DOTLOOP_BUILD_NAME": "1.0.31", "DOTLOOP_BUILD_NUMBER": "77"},
        )

    def test_new_release_and_each_cloud_rebuild_increment(self):
        spec = "name: app_gif\nversion: 1.0.30+32\n"
        self.assertEqual(build_version(spec, "1"), ("1.0.30", 33))
        self.assertEqual(build_version(spec, "42"), ("1.0.30", 74))
        self.assertEqual(build_version(spec, "43"), ("1.0.30", 75))

    def test_next_committed_release_keeps_incrementing(self):
        self.assertEqual(build_version("version: 1.0.31+33", "44"), ("1.0.31", 77))

    def test_missing_cloud_counter_does_not_silently_reuse_build(self):
        for counter in ["", "0", "-1", "abc", "1.5"]:
            with self.subTest(counter=counter), self.assertRaises(ValueError):
                build_version("version: 1.0.30+32", counter)

    def test_missing_or_malformed_committed_version_is_rejected(self):
        for spec in ["", "version: 1.0.30", "version: latest+32"]:
            with self.subTest(spec=spec), self.assertRaises(ValueError):
                build_version(spec, "1")

    def test_ios_build_number_limit_is_explicit(self):
        with self.assertRaises(ValueError):
            build_version("version: 1.0.30+32", "10000")


if __name__ == "__main__":
    unittest.main()

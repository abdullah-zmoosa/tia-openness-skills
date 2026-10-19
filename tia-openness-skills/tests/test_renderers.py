"""Offline tests for the Python renderers (no TIA Portal needed).

Run: python -m unittest discover -s tests -v
Fixtures in tests/fixtures are synthetic - never add real PLC projects here.
"""
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
TOOLS = ROOT / "skills" / "tia-reader" / "tools"
FIXTURE = ROOT / "tests" / "fixtures" / "export"


def run(script, *args):
    r = subprocess.run([sys.executable, "-I", str(TOOLS / script), *map(str, args)],
                       capture_output=True, text=True, encoding="utf-8")
    if r.returncode != 0:
        raise AssertionError(f"{script} failed ({r.returncode}):\n{r.stdout}\n{r.stderr}")
    return r.stdout


class RendererTests(unittest.TestCase):
    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp())
        self.exp = self.tmp / "export"
        shutil.copytree(FIXTURE, self.exp)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_render_lad(self):
        run("render_lad.py", self.exp / "blocks")
        out = (self.exp / "blocks" / "FC_Demo.lad.txt").read_text(encoding="utf-8")
        for word in ("Network 1", "Motor run", "Start", "Stop", "Motor"):
            self.assertIn(word, out)
        self.assertIn("[empty network]", out)
        self.assertNotIn("SCL", out)

    def test_stl_dump(self):
        run("stl_dump.py", self.exp / "blocks")
        out = (self.exp / "blocks" / "FC_StlDemo.stl").read_text(encoding="utf-8")
        self.assertIn('A       "Start"', out)
        self.assertIn('=       "Lamp"', out)

    def test_simaticml_flat_tags(self):
        run("simaticml_flat.py", self.exp)
        out = (self.exp / "tags" / "_PLC_TAGS.txt").read_text(encoding="utf-8")
        self.assertIn("%I0.0", out)
        self.assertIn("Start push button", out)
        self.assertIn("%Q0.0", out)
        self.assertTrue((self.exp / "tags" / "Demo tags.xml.txt").exists())

    def test_compare_identical(self):
        other = self.tmp / "other" / "export"
        shutil.copytree(FIXTURE, other)
        out = run("compare_exports.py", self.exp, other)
        self.assertIn("0 differ", out)

    def test_compare_detects_change_and_ignores_timestamps(self):
        other = self.tmp / "other" / "export"
        shutil.copytree(FIXTURE, other)
        f = other / "blocks" / "FC_Demo.xml"
        t = f.read_text(encoding="utf-8")
        t = t.replace("<Created>2026-01-01T00:00:00Z</Created>", "<Created>2099-12-31T23:59:59Z</Created>")
        f.write_text(t, encoding="utf-8")
        self.assertIn("0 differ", run("compare_exports.py", self.exp, other))
        f.write_text(t.replace('Name="Motor"', 'Name="Pump"'), encoding="utf-8")
        out = run("compare_exports.py", self.exp, other)
        self.assertIn("1 differ", out)
        self.assertIn("Pump", out)


if __name__ == "__main__":
    unittest.main()

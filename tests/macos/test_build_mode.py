"""The macOS platform-only build must never masquerade as a product install."""

from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(sys.platform == "darwin" and shutil.which("zig"),
                     "requires native macOS and Zig 0.17.0")
class BuildModeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="thin-build-mode-")
        cls.directory = Path(cls.temporary.name)

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def build(self, *arguments):
        prefix = self.directory / "install"
        command = ["zig", "build", *arguments, "--cache-dir", str(self.directory / "cache"),
                   "--prefix", str(prefix)]
        result = subprocess.run(command, cwd=ROOT, text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, timeout=120)
        self.assertFalse((prefix / "bin" / "thin").exists(), result.stdout)
        return result

    def test_default_macos_product_remains_rejected(self):
        result = self.build()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("supports Linux x86_64 only", result.stdout)

    def test_platform_only_default_install_explicitly_fails(self):
        result = self.build("-Dplatform-tests-only=true")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("platform-tests-only does not build thin", result.stdout)

    def test_platform_only_run_explicitly_fails(self):
        result = self.build("run", "-Dplatform-tests-only=true")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("platform-tests-only does not build thin", result.stdout)


if __name__ == "__main__":
    unittest.main()

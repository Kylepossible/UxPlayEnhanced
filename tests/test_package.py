import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('package', Path(__file__).resolve().parents[1] / 'scripts/verify_package.py')
package = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package)


class PackageTests(unittest.TestCase):
    def fixture(self, root):
        for name in package.REQUIRED:
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.touch()

    def test_missing_tray_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.fixture(root)
            (root / 'UxPlayEnhanced.exe').unlink()
            with patch.object(package, 'imports', return_value=set()):
                with self.assertRaisesRegex(RuntimeError, 'Missing required file: UxPlayEnhanced.exe'):
                    package.verify(root)

    def test_missing_transitive_dll_and_runtime_resolution(self):
        with tempfile.TemporaryDirectory() as directory, tempfile.TemporaryDirectory() as runtime:
            root = Path(directory)
            self.fixture(root)
            (Path(runtime) / 'vulkan-1.dll').touch()
            def imports(path):
                return {'vulkan-1.dll', 'kernel32.dll'} if path.name == 'uxplay.exe' else set()
            with patch.object(package, 'imports', side_effect=imports):
                with self.assertRaisesRegex(RuntimeError, 'imports missing vulkan-1.dll'):
                    package.verify(root)
                package.verify(root, runtime)
                self.assertTrue((root / 'vulkan-1.dll').exists())
                package.verify(root)


if __name__ == '__main__':
    unittest.main()

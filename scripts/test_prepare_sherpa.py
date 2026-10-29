import json
from pathlib import Path
import tempfile
import unittest
import prepare_sherpa as prepare


class ArtifactCacheTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "Info.plist").write_bytes(b"test metadata")
        self.binary = self.root / "ios-arm64/onnxruntime.framework/onnxruntime"
        self.binary.parent.mkdir(parents=True)
        self.binary.write_bytes(b"static archive")
        (self.root / "prepared.json").write_text(json.dumps({
            "sha256": prepare.DIGEST, "layout": prepare.LAYOUT,
            "files": prepare.file_digests(self.root)
        }))

    def test_complete_unchanged_cache_is_reused(self):
        self.assertTrue(prepare.cache_valid(self.root))

    def test_missing_binary_requires_rebuild(self):
        self.binary.unlink()
        self.assertFalse(prepare.cache_valid(self.root))

    def test_corrupt_binary_requires_rebuild(self):
        self.binary.write_bytes(b"broken archive")
        self.assertFalse(prepare.cache_valid(self.root))

    def test_invalid_marker_requires_rebuild(self):
        (self.root / "prepared.json").write_text("{broken")
        self.assertFalse(prepare.cache_valid(self.root))

    def test_old_marker_only_cache_is_not_trusted(self):
        (self.root / "prepared.json").write_text(json.dumps({"sha256": prepare.DIGEST, "layout": 1}))
        self.assertFalse(prepare.cache_valid(self.root))


class ModuleMapTests(unittest.TestCase):
    def test_transitive_c_headers_are_declared_without_cpp_headers(self):
        with tempfile.TemporaryDirectory() as directory:
            headers = Path(directory)
            (headers / "onnxruntime_c_api.h").write_text('#include "onnxruntime_ep_c_api.h"\n')
            (headers / "onnxruntime_ep_c_api.h").write_text('#include "onnxruntime_c_api.h"\n')
            (headers / "onnxruntime_cxx_api.h").write_text('#include <vector>\n')
            result = prepare.onnx_module_map(headers)
            self.assertIn('header "onnxruntime_c_api.h"', result)
            self.assertIn('header "onnxruntime_ep_c_api.h"', result)
            self.assertNotIn('onnxruntime_cxx_api.h', result)


if __name__ == "__main__":
    unittest.main()

"""A stale or modified shared Core archive must never be linked into a passing fixture."""
import copy
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from media_test_support import CoreArtifactsError, core_inputs, validate_artifacts, write_artifact_manifest


class CoreArtifactCacheTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="core-cache-contract-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.package = self.root / "Packages/BoringCore"
        self.source = self.package / "Sources/BoringCore/Value.swift"
        self.source.parent.mkdir(parents=True)
        self.source.write_text("public let value = 1\n")
        (self.package / "Package.swift").write_text("// fixture manifest with Swift 6 static product\n")
        self.artifacts = self.root / "build"
        (self.artifacts / "Modules").mkdir(parents=True)
        (self.artifacts / "libBoringCore.a").write_bytes(b"!<arch>\nfixture object")
        (self.artifacts / "Modules/BoringCore.swiftmodule").write_bytes(b"fixture module")
        self.compiler = {"executable": "/fixture/swiftc", "version": "Swift 6 fixture", "sdk": "/fixture/SDK", "target": {"triple": "fixture"}}
        write_artifact_manifest(self.artifacts, core_inputs(self.root, self.compiler))

    def test_unchanged_build_reuses_actual_module_and_archive_paths(self):
        arguments = validate_artifacts(self.artifacts, self.root, self.compiler)
        self.assertIn(str(self.artifacts / "Modules"), arguments)
        self.assertIn(str(self.artifacts), arguments)
        self.assertEqual(arguments[-1], "-lBoringCore")

    def test_source_manifest_and_compiler_changes_reject_stale_build(self):
        for path in [self.source, self.package / "Package.swift"]:
            original = path.read_bytes()
            path.write_bytes(original + b"// changed\n")
            with self.assertRaises(CoreArtifactsError):
                validate_artifacts(self.artifacts, self.root, self.compiler)
            path.write_bytes(original)
        changed = copy.deepcopy(self.compiler)
        changed["version"] = "different compiler build"
        with self.assertRaises(CoreArtifactsError):
            validate_artifacts(self.artifacts, self.root, changed)

    def test_changed_or_missing_archive_and_module_are_rejected(self):
        for path in [self.artifacts / "libBoringCore.a", self.artifacts / "Modules/BoringCore.swiftmodule"]:
            original = path.read_bytes()
            path.write_bytes(original + b"modified")
            with self.assertRaises(CoreArtifactsError):
                validate_artifacts(self.artifacts, self.root, self.compiler)
            path.unlink()
            with self.assertRaises(CoreArtifactsError):
                validate_artifacts(self.artifacts, self.root, self.compiler)
            path.write_bytes(original)


if __name__ == "__main__":
    unittest.main()

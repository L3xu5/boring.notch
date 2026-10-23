"""Link platform fixtures to verified SwiftPM Core artifacts, or compile Core standalone.

Cached archives are accepted only for the current package/source/toolchain identity, and their
bytes are checked before linking. The orchestrator keeps that build in a private temporary tree.
"""
from __future__ import annotations

from functools import lru_cache
from hashlib import sha256
import json
import os
from pathlib import Path
import subprocess
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
ARTIFACTS_ENV = "BORING_CORE_ARTIFACTS_DIR"
MANIFEST_NAME = "boring-core-artifacts.json"
LANGUAGE_MODE = 6


class CoreArtifactsError(RuntimeError):
    """An explicitly supplied Core cache is stale or incomplete; silently rebuilding hides it."""


@lru_cache(maxsize=1)
def compiler_identity() -> dict[str, Any]:
    def output(*arguments: str) -> str:
        return subprocess.check_output(arguments, text=True, stderr=subprocess.PIPE).strip()

    sdk = output("xcrun", "--sdk", "macosx", "--show-sdk-path")
    return {
        "executable": output("xcrun", "--find", "swiftc"),
        "version": output("xcrun", "swiftc", "--version"),
        "sdk": sdk,
        "target": json.loads(output("xcrun", "swiftc", "-sdk", sdk, "-print-target-info"))["target"],
    }


def digest(path: Path) -> str:
    checksum = sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            checksum.update(chunk)
    return checksum.hexdigest()


def core_inputs(root: Path = ROOT, compiler: dict[str, Any] | None = None) -> dict[str, Any]:
    package = root / "Packages/BoringCore"
    sources = sorted((package / "Sources/BoringCore").rglob("*.swift"))
    if not sources or not (package / "Package.swift").is_file():
        raise CoreArtifactsError("BoringCore package sources are missing")
    files = [package / "Package.swift", *sources]
    return {
        "swift_language_mode": LANGUAGE_MODE,
        "configuration": "debug",
        "compiler": compiler if compiler is not None else compiler_identity(),
        "sources": {str(path.relative_to(root)): digest(path) for path in files},
    }


def inputs_fingerprint(inputs: dict[str, Any]) -> str:
    return sha256(json.dumps(inputs, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def artifact_files(directory: Path) -> list[Path]:
    archive = directory / "libBoringCore.a"
    module = directory / "Modules/BoringCore.swiftmodule"
    if not archive.is_file() or not module.exists():
        raise CoreArtifactsError("The SwiftPM BoringCore static archive or module is missing")
    with archive.open("rb") as stream:
        if stream.read(8) != b"!<arch>\n":
            raise CoreArtifactsError("BoringCore must be built as a static archive")
    files = [archive]
    for path in sorted((directory / "Modules").glob("BoringCore.*")):
        files.extend(sorted(item for item in path.rglob("*") if item.is_file()) if path.is_dir() else [path])
    return files


def write_artifact_manifest(directory: Path, inputs: dict[str, Any]) -> None:
    files = artifact_files(directory)
    metadata = {
        "schema": 1,
        "fingerprint": inputs_fingerprint(inputs),
        "inputs": inputs,
        "artifacts": {str(path.relative_to(directory)): digest(path) for path in files},
    }
    (directory / MANIFEST_NAME).write_text(json.dumps(metadata, sort_keys=True, indent=2) + "\n")


def validate_artifacts(directory: Path, root: Path = ROOT,
                       compiler: dict[str, Any] | None = None) -> list[str]:
    try:
        metadata = json.loads((directory / MANIFEST_NAME).read_text())
        expected = core_inputs(root, compiler)
        if metadata.get("schema") != 1 or metadata.get("inputs") != expected:
            raise CoreArtifactsError("BoringCore artifacts do not match the current sources, package or compiler")
        if metadata.get("fingerprint") != inputs_fingerprint(expected):
            raise CoreArtifactsError("BoringCore artifact fingerprint is inconsistent")
        actual_files = artifact_files(directory)
        actual = {str(path.relative_to(directory)): digest(path) for path in actual_files}
        if metadata.get("artifacts") != actual:
            raise CoreArtifactsError("BoringCore archive or module changed after its build was verified")
    except (OSError, ValueError, KeyError, TypeError) as error:
        raise CoreArtifactsError("BoringCore artifact cache is unreadable; run check_project.py --native-only again") from error
    return ["-I", str(directory / "Modules"), "-L", str(directory), "-lBoringCore"]


def core_arguments(directory: Path) -> list[str]:
    supplied = os.environ.get(ARTIFACTS_ENV)
    if supplied:
        return validate_artifacts(Path(supplied).resolve())
    # Standalone platform scripts still work without SwiftPM orchestration. This compiles the
    # actual module in Swift 6, never extracted or copied algorithms in a fixture class.
    sources = sorted((ROOT / "Packages/BoringCore/Sources/BoringCore").rglob("*.swift"))
    subprocess.run([
        "xcrun", "swiftc", "-swift-version", str(LANGUAGE_MODE), "-parse-as-library",
        "-module-cache-path", str(directory / "ModuleCache"),
        "-emit-library", "-static", "-emit-module", "-module-name", "BoringCore",
        "-emit-module-path", str(directory / "BoringCore.swiftmodule"),
        *map(str, sources), "-o", str(directory / "libBoringCore.a"),
    ], check=True, timeout=120)
    return ["-I", str(directory), "-L", str(directory), "-lBoringCore"]

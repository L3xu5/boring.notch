#!/usr/bin/env python3
"""Link the actual stream owner/Core framer against deterministic real Pipe byte streams."""

from pathlib import Path
from media_test_support import core_arguments
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def main() -> None:
    fixture = (ROOT / "Tests/MediaStreamTests.swift").read_text()
    with tempfile.TemporaryDirectory(prefix="boring-notch-media-stream-tests-") as directory:
        directory = Path(directory)
        swift = directory / "MediaStreamTests.swift"
        domain_arguments = core_arguments(directory)
        executable = directory / "media-stream-tests"
        swift.write_text(fixture)
        subprocess.run([
            "xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
            "-module-cache-path", str(directory / "ModuleCache"),
            *domain_arguments,
            str(swift), str(ROOT / "boringNotch/MediaControllers/MediaAdapterSession.swift"), "-o", str(executable),
        ], check=True, timeout=120)
        subprocess.run([str(executable)], check=True, timeout=30)


if __name__ == "__main__":
    main()

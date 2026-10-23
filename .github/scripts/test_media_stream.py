#!/usr/bin/env python3
"""Run the production JSON-lines pipe actor against deterministic real Pipe byte streams."""

from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def main() -> None:
    source = (ROOT / "boringNotch/MediaControllers/NowPlayingController.swift").read_text()
    handler = source[source.index("actor JSONLinesPipeHandler {"):]
    fixture = (ROOT / "Tests/MediaStreamTests.swift").read_text()
    fixture = fixture.replace("// PRODUCTION_PIPE_HANDLER", handler)
    with tempfile.TemporaryDirectory(prefix="boring-notch-media-stream-tests-") as directory:
        directory = Path(directory)
        swift = directory / "MediaStreamTests.swift"
        executable = directory / "media-stream-tests"
        swift.write_text(fixture)
        subprocess.run([
            "xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
            "-module-cache-path", str(directory / "ModuleCache"),
            str(swift), "-o", str(executable),
        ], check=True, timeout=120)
        subprocess.run([str(executable)], check=True, timeout=30)


if __name__ == "__main__":
    main()

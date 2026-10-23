#!/usr/bin/env python3
"""Run production lyrics resolution against deterministic Swift network/AppleScript fixtures.

The UI application has no test target. Compile its actual lyrics methods and Yandex provider
with small platform fixtures so these regressions run without launching a player or using
real credentials/network services. No production logic is copied into the fixtures.
"""

from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def main() -> None:
    source = (ROOT / "boringNotch/managers/MusicManager.swift").read_text()
    properties = source[
        source.index("    // Cache of successfully fetched lyrics"):
        source.index("    // Store last values at the time artwork was changed")
    ]
    methods = source[
        source.index("    // MARK: - Lyrics\n"):
        source.index("    private func triggerFlipAnimation()")
    ]
    provider = source[source.index("struct YandexLyricsProvider {"):]
    fixture = (ROOT / "Tests/LyricsRegressionTests.swift").read_text()
    fixture = fixture.replace("    // PRODUCTION_LYRICS_PROPERTIES", properties)
    fixture = fixture.replace("    // PRODUCTION_LYRICS_METHODS", methods)
    fixture = fixture.replace("// PRODUCTION_YANDEX_PROVIDER", provider)
    with tempfile.TemporaryDirectory(prefix="boring-notch-lyrics-tests-") as directory:
        directory = Path(directory)
        swift = directory / "LyricsRegressionTests.swift"
        executable = directory / "lyrics-tests"
        swift.write_text(fixture)
        subprocess.run([
            "xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
            "-module-cache-path", str(directory / "ModuleCache"),
            str(swift), "-o", str(executable),
        ], check=True, timeout=120)
        subprocess.run([str(executable)], check=True, timeout=30)


if __name__ == "__main__":
    main()

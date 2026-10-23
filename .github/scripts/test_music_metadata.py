#!/usr/bin/env python3
"""Exercise MusicManager's actual state/artwork methods with deterministic image fixtures."""

from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def main() -> None:
    source = (ROOT / "boringNotch/managers/MusicManager.swift").read_text()
    update = source[
        source.index("    @MainActor\n    private func updateFromPlaybackState"):
        source.index("    func toggleFavoriteTrack()")
    ]
    artwork = source[
        source.index("    private func updateArtwork("):
        source.index("    private func updateIdleState(")
    ]
    album = source[
        source.index("    func updateAlbumArt("):
        source.index("    // MARK: - Playback Position Estimation")
    ]
    color = source[
        source.index("    func calculateAverageColor()"):
        source.index("    private func updateSneakPeek()")
    ]
    state = (ROOT / "boringNotch/models/PlaybackState.swift").read_text()
    fixture = (ROOT / "Tests/MusicMetadataRegressionTests.swift").read_text()
    fixture = fixture.replace("// PRODUCTION_PLAYBACK_STATE", state)
    fixture = fixture.replace("    // PRODUCTION_METADATA_METHODS", update + artwork + album + color)
    with tempfile.TemporaryDirectory(prefix="boring-notch-metadata-tests-") as directory:
        directory = Path(directory)
        swift = directory / "MusicMetadataRegressionTests.swift"
        executable = directory / "metadata-tests"
        swift.write_text(fixture)
        subprocess.run([
            "xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
            "-module-cache-path", str(directory / "ModuleCache"),
            str(swift), "-o", str(executable),
        ], check=True, timeout=120)
        subprocess.run([str(executable)], check=True, timeout=30)


if __name__ == "__main__":
    main()

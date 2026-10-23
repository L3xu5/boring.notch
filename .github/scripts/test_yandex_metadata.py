#!/usr/bin/env python3
"""Run the production Yandex controller against JSON-lines adapter/AX fixtures on macOS."""

from pathlib import Path
import plistlib
import subprocess
import tempfile


def main():
    root = Path(__file__).resolve().parents[2]
    with tempfile.TemporaryDirectory(prefix="boring-notch-yandex-metadata-") as directory:
        temporary = Path(directory)
        contents = temporary / "YandexMetadataTests.app/Contents"
        (contents / "MacOS").mkdir(parents=True)
        (contents / "Resources").mkdir()
        (contents / "Frameworks/MediaRemoteAdapter.framework").mkdir(parents=True)
        (contents / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "local.boring-notch.YandexMetadataTests",
            "CFBundleExecutable": "YandexMetadataTests", "CFBundlePackageType": "APPL",
        }))
        (contents / "Resources/mediaremote-adapter.pl").write_text("""use strict;
use warnings;
$| = 1;
open(my $fixture, '<', $ENV{'YANDEX_METADATA_FIXTURE'}) or die $!;
while (my $line = <$fixture>) { print $line; select(undef, undef, undef, 0.01); }
close($fixture);
open(my $done, '>', $ENV{'YANDEX_METADATA_DONE'}) or die $!;
close($done);
while (1) { sleep(1); }
""")
        controller = (root / "boringNotch/MediaControllers/YandexMusicController.swift").read_text()
        tests = (root / "Tests/YandexMetadataRegressionTests.swift").read_text()
        source = temporary / "YandexMetadataTests.swift"
        source.write_text(controller + "\n" + tests)
        shared = (root / "boringNotch/MediaControllers/NowPlayingController.swift").read_text()
        handler = temporary / "PipeHandler.swift"
        handler.write_text("import Foundation\n" + shared[shared.index("struct NowPlayingUpdate:"):])
        executable = contents / "MacOS/YandexMetadataTests"
        subprocess.run([
            "swiftc", "-swift-version", "5", "-parse-as-library",
            "-module-cache-path", str(temporary / "ModuleCache"),
            str(source), str(handler), str(root / "boringNotch/models/PlaybackState.swift"),
            str(root / "boringNotch/MediaControllers/MediaControllerProtocol.swift"),
            "-o", str(executable),
        ], check=True, cwd=root)
        subprocess.run([str(executable)], check=True, cwd=root, timeout=60)


if __name__ == "__main__":
    main()

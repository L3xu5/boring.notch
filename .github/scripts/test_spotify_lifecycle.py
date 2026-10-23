#!/usr/bin/env python3
"""Link the complete Spotify controller with injected metadata and delayed image backends."""
from pathlib import Path
import subprocess
import tempfile
from media_test_support import core_arguments
ROOT = Path(__file__).resolve().parents[2]

def main():
    with tempfile.TemporaryDirectory(prefix='boring-notch-spotify-tests-') as directory:
        directory = Path(directory)
        executable = directory / 'spotify-tests'
        domain = core_arguments(directory)
        sources = [
            'boringNotch/MediaControllers/SpotifyController.swift',
            'boringNotch/MediaControllers/MediaControllerProtocol.swift',
            'boringNotch/MediaControllers/MediaApplicationObserver.swift',
            'boringNotch/helpers/AppleScriptHelper.swift',
            'boringNotch/managers/ImageService.swift',
            'boringNotch/models/PlaybackState.swift',
            'Tests/SpotifyLifecycleTests.swift',
        ]
        subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library',
                        '-module-cache-path', str(directory / 'ModuleCache'), *domain,
                        *[str(ROOT / source) for source in sources], '-o', str(executable)], check=True, timeout=120)
        subprocess.run([str(executable)], check=True, timeout=30)

if __name__ == '__main__':
    main()

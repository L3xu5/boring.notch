#!/usr/bin/env python3
"""Exercise the actual image HTTP service with a session-local fake URL protocol."""
from pathlib import Path
import subprocess
import tempfile
ROOT = Path(__file__).resolve().parents[2]

def main():
    with tempfile.TemporaryDirectory(prefix='boring-notch-artwork-tests-') as directory:
        directory = Path(directory)
        executable = directory / 'artwork-tests'
        subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library',
                        '-module-cache-path', str(directory / 'ModuleCache'),
                        str(ROOT / 'boringNotch/managers/ImageService.swift'),
                        str(ROOT / 'Tests/ArtworkTransportTests.swift'), '-o', str(executable)], check=True, timeout=120)
        subprocess.run([str(executable)], check=True, timeout=30)

if __name__ == '__main__':
    main()

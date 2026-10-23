#!/usr/bin/env python3
"""Verify the actual bounded probe coordinator without launching a real Now Playing client."""
from pathlib import Path
import subprocess
import tempfile
from media_test_support import core_arguments
ROOT = Path(__file__).resolve().parents[2]

def main():
    with tempfile.TemporaryDirectory(prefix='boring-notch-probe-tests-') as directory:
        directory = Path(directory)
        executable = directory / 'probe-tests'
        domain = core_arguments(directory)
        subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library',
                        '-module-cache-path', str(directory / 'ModuleCache'), *domain,
                        str(ROOT / 'boringNotch/helpers/MediaChecker.swift'),
                        str(ROOT / 'Tests/MediaCheckerTests.swift'), '-o', str(executable)], check=True, timeout=120)
        subprocess.run([str(executable)], check=True, timeout=30)

if __name__ == '__main__':
    main()

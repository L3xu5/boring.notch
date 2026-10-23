#!/usr/bin/env python3
"""Exercise actual Shelf factories in an exact Debug preview bundle, never production storage."""
from pathlib import Path
import plistlib
import subprocess
import tempfile
from media_test_support import ROOT, core_arguments


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="boring-shelf-preview-") as temporary:
        directory = Path(temporary)
        application = directory / "ShelfPreviewIsolationTests.app"
        executable = application / "Contents/MacOS/ShelfPreviewIsolationTests"
        executable.parent.mkdir(parents=True)
        with (application / "Contents/Info.plist").open("wb") as output:
            plistlib.dump({"CFBundleIdentifier": "local.boringnotch.preview", "CFBundleExecutable": executable.name,
                          "CFBundleName": "Shelf Preview Isolation Tests", "CFBundlePackageType": "APPL"}, output)
        sources = [
            "Tests/ShelfPreviewIsolationTests.swift",
            "boringNotch/Providers/CalendarServiceProviding.swift",
            "boringNotch/models/CalendarModel.swift",
            "boringNotch/models/EventModel.swift",
            "boringNotch/components/Shelf/Services/ShelfStorageEnvironment.swift",
            "boringNotch/components/Shelf/Services/ShelfPersistenceService.swift",
            "boringNotch/components/Shelf/Services/TemporaryFileStorageService.swift",
            "boringNotch/components/Shelf/Services/ShelfMetadataService.swift",
            "boringNotch/components/Shelf/Services/ThumbnailService.swift",
            "boringNotch/components/Shelf/Services/ShelfDropService.swift",
            "boringNotch/components/Shelf/Models/ShelfItem.swift",
            "boringNotch/components/Shelf/Models/Bookmark.swift",
            "boringNotch/components/Shelf/ViewModels/ShelfStateViewModel.swift",
            "boringNotch/components/Shelf/ViewModels/ShelfSelectionModel.swift",
            "boringNotch/extensions/URL+SecurityScoped.swift",
            "boringNotch/extensions/NSItemProvider+LoadHelpers.swift",
        ]
        subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-DDEBUG", "-parse-as-library",
                        "-module-cache-path", str(directory / "ModuleCache"), *core_arguments(directory),
                        *[str(ROOT / source) for source in sources], "-o", str(executable)], check=True, timeout=180)
        subprocess.run([str(executable), "--ui-snapshot", "--fixture-root", str(directory)], check=True, timeout=30)
        # A second bundle identity exercises a failed live read with a temporary injected path.
        # It never calls a default production path factory or constructs the shared model.
        with (application / "Contents/Info.plist").open("wb") as output:
            plistlib.dump({"CFBundleIdentifier": "local.boringnotch.shelf-storage-tests", "CFBundleExecutable": executable.name,
                          "CFBundleName": "Shelf Storage Tests", "CFBundlePackageType": "APPL"}, output)
        subprocess.run([str(executable), "--load-error-mode", "--fixture-root", str(directory)], check=True, timeout=30)


if __name__ == "__main__":
    main()

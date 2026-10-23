#!/usr/bin/env python3
"""Render developer-only native UI snapshots from an isolated, ad-hoc signed app copy."""
from __future__ import annotations

import argparse
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile


def validate_debug_bundle(app: Path) -> dict:
    """Reject a Release/unknown executable before copying, signing or launching anything."""
    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    if info.get("BNBuildConfiguration") != "Debug":
        raise ValueError("UI snapshots require this project's Debug build with isolated preview support; Release builds are never launched")
    executable = info.get("CFBundleExecutable")
    if not isinstance(executable, str) or not executable or Path(executable).name != executable:
        raise ValueError("Invalid app executable in Info.plist")
    if not (app / "Contents/MacOS" / executable).is_file():
        raise ValueError("App executable is missing")
    return info


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--pages", nargs="+", default=["general", "appearance", "media", "shortcuts", "notch", "onboarding"])
    parser.add_argument("--appearance", choices=["light", "dark"], default="dark")
    args = parser.parse_args()
    try:
        validate_debug_bundle(args.app)
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        parser.error(str(error))
    args.output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="boring-notch-ui-preview-") as directory:
        preview = Path(directory) / "Boring Notch Preview.app"
        shutil.copytree(args.app, preview, symlinks=True)
        metadata = preview / "Contents/Info.plist"
        with metadata.open("rb") as stream:
            info = plistlib.load(stream)
        info["CFBundleIdentifier"] = "local.boringnotch.preview"
        info["CFBundleDisplayName"] = "Boring Notch Preview"
        with metadata.open("wb") as stream:
            plistlib.dump(info, stream)
        subprocess.run(["codesign", "--force", "--deep", "--timestamp=none", "--sign", "-", str(preview)], check=True, capture_output=True)
        executable = preview / "Contents/MacOS" / info["CFBundleExecutable"]
        for page in args.pages:
            output = args.output.resolve() / f"{page}-{args.appearance}.png"
            result = subprocess.run([
                str(executable), "--ui-snapshot", "--snapshot-page", page,
                "--snapshot-output", str(output), "--snapshot-appearance", args.appearance,
            ], capture_output=True, text=True, timeout=45)
            if result.returncode or not output.is_file():
                raise RuntimeError(f"Snapshot {page} failed ({result.returncode}):\n{result.stderr[-6000:]}")
            print(output)


if __name__ == "__main__":
    main()

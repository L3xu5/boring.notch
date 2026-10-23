#!/usr/bin/env python3
"""Create the fork's Sparkle feed from the metadata in the built application."""

from __future__ import annotations

import argparse
import base64
import binascii
from datetime import datetime, timezone
from email.utils import format_datetime
from pathlib import Path
import plistlib
import re
import sys
from urllib.parse import urlsplit
import xml.etree.ElementTree as ET


SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ED_SIGNATURE = f"{{{SPARKLE_NS}}}edSignature"
POSITIVE_INTEGER = re.compile(r"[1-9][0-9]*")

ET.register_namespace("sparkle", SPARKLE_NS)


def parse_signature(signature_output: str, archive_size: int) -> str:
    """Validate sign_update's attributes before copying them into the feed."""
    try:
        attributes = ET.fromstring(
            f'<signature xmlns:sparkle="{SPARKLE_NS}" {signature_output.strip()} />'
        ).attrib
    except ET.ParseError as error:
        raise ValueError("Invalid sign_update output") from error

    if set(attributes) != {ED_SIGNATURE, "length"}:
        raise ValueError("sign_update output must contain edSignature and length")

    length = attributes["length"]
    if not POSITIVE_INTEGER.fullmatch(length) or int(length) != archive_size:
        raise ValueError("Signature length does not match the archive size")

    signature = attributes[ED_SIGNATURE]
    try:
        decoded_signature = base64.b64decode(signature, validate=True)
    except (binascii.Error, ValueError) as error:
        raise ValueError("Invalid base64 Ed25519 signature") from error
    if len(decoded_signature) != 64:
        raise ValueError("An Ed25519 signature must contain 64 bytes")
    return signature


def create_appcast(
    app: Path,
    archive: Path,
    download_url: str,
    signature_output: str,
) -> ET.ElementTree:
    with (app / "Contents" / "Info.plist").open("rb") as plist_file:
        metadata = plistlib.load(plist_file)

    version = metadata.get("CFBundleVersion")
    if not isinstance(version, str) or not POSITIVE_INTEGER.fullmatch(version):
        raise ValueError("CFBundleVersion must be a positive integer string")
    short_version = metadata.get("CFBundleShortVersionString")
    if not isinstance(short_version, str) or not short_version.strip():
        raise ValueError("CFBundleShortVersionString must not be empty")
    minimum_system = metadata.get("LSMinimumSystemVersion")
    if not isinstance(minimum_system, str) or not minimum_system.strip():
        raise ValueError("LSMinimumSystemVersion must not be empty")

    parsed_url = urlsplit(download_url)
    if (
        parsed_url.scheme != "https"
        or not parsed_url.hostname
        or any(character.isspace() for character in download_url)
    ):
        raise ValueError("The download URL must be an absolute HTTPS URL")

    if not archive.is_file():
        raise ValueError("The update archive must be a file")
    archive_size = archive.stat().st_size
    if archive_size <= 0:
        raise ValueError("The update archive must not be empty")
    signature = parse_signature(signature_output, archive_size)

    root = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(root, "channel")
    ET.SubElement(channel, "title").text = "Boring Notch — Yandex Music Edition"
    ET.SubElement(channel, "link").text = download_url
    ET.SubElement(channel, "description").text = "Rolling builds of the Yandex Music fork."

    item = ET.SubElement(channel, "item")
    ET.SubElement(item, "title").text = f"Build {version}"
    ET.SubElement(item, "pubDate").text = format_datetime(datetime.now(timezone.utc))
    ET.SubElement(item, f"{{{SPARKLE_NS}}}version").text = version
    ET.SubElement(item, f"{{{SPARKLE_NS}}}shortVersionString").text = short_version
    ET.SubElement(item, f"{{{SPARKLE_NS}}}minimumSystemVersion").text = minimum_system
    ET.SubElement(
        item,
        "enclosure",
        {
            "url": download_url,
            ED_SIGNATURE: signature,
            "length": str(archive_size),
            "type": "application/octet-stream",
        },
    )
    tree = ET.ElementTree(root)
    ET.indent(tree, space="  ")
    return tree


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--archive", required=True, type=Path)
    parser.add_argument("--download-url", required=True)
    parser.add_argument("--signature", required=True)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args(argv)

    try:
        tree = create_appcast(args.app, args.archive, args.download_url, args.signature)
        tree.write(args.output, encoding="utf-8", xml_declaration=True)
    except Exception as error:
        print(f"::error::{error}", file=sys.stderr)
        return 1

    print(f"Generated appcast at {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

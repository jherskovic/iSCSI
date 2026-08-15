#!/usr/bin/env python3
"""Insert or replace one release in appcast.xml.

    update-appcast.py --version 0.3.0 --build 7 --dmg build/x.dmg \
        --signature "..." --length 5812345 --url https://.../x.dmg

Sparkle's own generate_appcast scans a directory of every past build and
rewrites the feed from it. That would mean keeping every DMG ever shipped on
the release machine, and silently dropping any version whose file was tidied
away. This edits the feed in place instead: one release in, one <item> out,
everything else untouched.

The feed is the contract with every installed copy of the app. A malformed or
truncated appcast does not fail loudly — Sparkle just stops offering updates,
and nobody notices until someone asks why they are three versions behind. So
this validates what it produced before it writes.
"""

import argparse
import os
import sys
import xml.etree.ElementTree as ET
from datetime import datetime, timezone

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE_NS)

EMPTY_FEED = """<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>iSCSI Initiator</title>
    <description>Updates for iSCSI Initiator.</description>
    <language>en</language>
  </channel>
</rss>
"""


def sparkle(tag: str) -> str:
    return f"{{{SPARKLE_NS}}}{tag}"


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--appcast", default="appcast.xml")
    p.add_argument("--version", required=True, help="marketing version, e.g. 0.3.0")
    p.add_argument("--build", required=True, help="CFBundleVersion, the sort key")
    p.add_argument("--signature", required=True)
    p.add_argument("--length", required=True)
    p.add_argument("--url", required=True, help="where the DMG will be downloadable")
    p.add_argument("--min-system", default="26.0")
    p.add_argument("--notes-url", default="")
    args = p.parse_args()

    # Entity-expansion attacks live in a DOCTYPE, and a legitimate appcast has
    # no reason to carry one. Refusing outright is cheaper and more certain than
    # taking a dependency on defusedxml in a release script — and this file is
    # ours, generated here and committed, so anyone who could poison it already
    # has commit access.
    if os.path.exists(args.appcast):
        with open(args.appcast, "r", encoding="utf-8") as f:
            if "<!DOCTYPE" in f.read(4096):
                print("refusing to parse an appcast containing a DOCTYPE",
                      file=sys.stderr)
                return 1

    if not os.path.exists(args.appcast):
        with open(args.appcast, "w") as f:
            f.write(EMPTY_FEED)

    tree = ET.parse(args.appcast)
    channel = tree.getroot().find("channel")
    if channel is None:
        print("appcast has no <channel>", file=sys.stderr)
        return 1

    # Replace rather than append: re-cutting a release that was never published
    # is normal, and two <item>s for one build would leave Sparkle picking
    # whichever it saw first.
    for item in channel.findall("item"):
        existing = item.find(sparkle("version"))
        if existing is not None and existing.text == args.build:
            channel.remove(item)

    item = ET.Element("item")
    ET.SubElement(item, "title").text = f"Version {args.version}"
    ET.SubElement(item, "pubDate").text = datetime.now(timezone.utc).strftime(
        "%a, %d %b %Y %H:%M:%S +0000")
    ET.SubElement(item, sparkle("version")).text = args.build
    ET.SubElement(item, sparkle("shortVersionString")).text = args.version
    ET.SubElement(item, sparkle("minimumSystemVersion")).text = args.min_system
    if args.notes_url:
        ET.SubElement(item, sparkle("releaseNotesLink")).text = args.notes_url

    enclosure = ET.SubElement(item, "enclosure")
    enclosure.set("url", args.url)
    enclosure.set("length", str(args.length))
    enclosure.set("type", "application/octet-stream")
    enclosure.set(sparkle("edSignature"), args.signature)

    # Newest first. Sparkle does not require it, but a human reading the feed to
    # work out what shipped when should not have to sort it in their head.
    items = channel.findall("item")
    for existing in items:
        channel.remove(existing)
    items.append(item)
    items.sort(key=lambda el: int(el.find(sparkle("version")).text or 0), reverse=True)
    for existing in items:
        channel.append(existing)

    ET.indent(tree, space="  ")
    tree.write(args.appcast, encoding="utf-8", xml_declaration=True)

    # Read it back. A feed that does not parse stops updates for everyone
    # already running the app, and does it silently.
    check = ET.parse(args.appcast)
    found = [
        el for el in check.getroot().find("channel").findall("item")
        if el.find(sparkle("version")).text == args.build
    ]
    if len(found) != 1:
        print(f"appcast verification failed: {len(found)} items for build {args.build}",
              file=sys.stderr)
        return 1
    enc = found[0].find("enclosure")
    if enc is None or not enc.get(sparkle("edSignature")):
        print("appcast verification failed: the new item has no signed enclosure",
              file=sys.stderr)
        return 1

    print(f"  appcast: {args.version} (build {args.build}) -> {args.url}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

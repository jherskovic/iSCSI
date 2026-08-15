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
    p.add_argument("--signature")
    p.add_argument("--length")
    p.add_argument("--url", help="where the DMG will be downloadable")
    p.add_argument("--min-system", default="26.0")
    p.add_argument("--notes-url", default="")
    # Run the refusals below and exit without touching the file. The release
    # pipeline calls this before it builds anything, so a forgotten build number
    # costs thirty seconds instead of an archive and two notarizations. Having
    # the early check call this script rather than restate its rule is the point:
    # a second copy of the rule is a second thing to get subtly wrong, and the
    # first draft of it was wrong — stricter than this one, and it rejected
    # re-cutting a version that had not shipped.
    p.add_argument("--check-only", action="store_true",
                   help="validate --version/--build against the feed, write nothing")
    args = p.parse_args()

    if not args.check_only:
        for required in ("signature", "length", "url"):
            if getattr(args, required) is None:
                p.error(f"--{required} is required unless --check-only is given")

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
        # Nothing to conflict with, and --check-only must not create the file:
        # it runs on a CI checkout that may be a dry run publishing nothing.
        if args.check_only:
            print(f"  no {args.appcast} yet; build {args.build} is free")
            return 0
        with open(args.appcast, "w") as f:
            f.write(EMPTY_FEED)

    tree = ET.parse(args.appcast)
    channel = tree.getroot().find("channel")
    if channel is None:
        print("appcast has no <channel>", file=sys.stderr)
        return 1

    # Sparkle orders and compares releases by sparkle:version — the build number
    # — and ignores the marketing string entirely. Two mistakes follow from that,
    # both of which produce a feed that looks fine and updates nobody:
    #
    #   * Shipping a new marketing version without bumping CURRENT_PROJECT_VERSION.
    #     The replace below would then delete the previous release's <item> and
    #     put the new one in its place, so the feed loses a release and every
    #     installed copy at that build number sees nothing newer than itself.
    #   * Going backwards. An item below the top of the feed is never offered.
    #
    # Neither is recoverable by looking at the output, so refuse both here.
    try:
        new_build = int(args.build)
    except ValueError:
        print(f"--build must be an integer, got {args.build!r}", file=sys.stderr)
        return 1

    builds = {}
    for item in channel.findall("item"):
        el = item.find(sparkle("version"))
        short = item.find(sparkle("shortVersionString"))
        if el is not None and el.text and el.text.strip().isdigit():
            builds[int(el.text)] = (short.text if short is not None else "?")

    if new_build in builds and builds[new_build] != args.version:
        print(f"build {args.build} is already in the feed as version "
              f"{builds[new_build]}, and this release calls itself {args.version}. "
              f"Bump CURRENT_PROJECT_VERSION in apps/project.yml — Sparkle compares "
              f"builds, not marketing versions, so reusing one would drop "
              f"{builds[new_build]} from the feed and offer nothing to anyone "
              f"already running it.", file=sys.stderr)
        return 1

    if builds and new_build < max(builds):
        print(f"build {args.build} is lower than {max(builds)}, already in the feed. "
              f"Sparkle only ever offers the highest build, so this entry would be "
              f"published and never seen.", file=sys.stderr)
        return 1

    if args.check_only:
        print(f"  build {args.build} is usable for version {args.version} "
              f"(feed tops out at {max(builds) if builds else 'nothing'})")
        return 0

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

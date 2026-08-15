#!/usr/bin/env python3
"""Print the download URL of the newest release in an appcast.

    appcast-newest-url.py appcast.xml
    curl -fsSL https://…/appcast.xml | appcast-newest-url.py -

"Newest" means the highest sparkle:version — the build number — because that is
what Sparkle itself compares. Reading the first <item> instead would agree with
the feed this repo generates, which is sorted, and disagree with any feed that
is not; the point of this script is to check the feed rather than to trust it.

Exits non-zero if the feed has no items, so a caller can retry a URL that has
not propagated yet rather than silently comparing against an empty string.
"""

import sys
import xml.etree.ElementTree as ET

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2

    if sys.argv[1] == "-":
        text = sys.stdin.read()
    else:
        with open(sys.argv[1], encoding="utf-8") as f:
            text = f.read()

    # Same rule as update-appcast.py: a legitimate appcast has no DOCTYPE, and
    # refusing one closes off entity expansion without taking a dependency on
    # defusedxml inside a release pipeline. This one matters more than the
    # writer's — it parses whatever the network hands back.
    if "<!DOCTYPE" in text[:4096]:
        print("refusing to parse an appcast containing a DOCTYPE", file=sys.stderr)
        return 1

    try:
        root = ET.fromstring(text)
    except ET.ParseError as exc:
        print(f"appcast does not parse: {exc}", file=sys.stderr)
        return 1

    def build(item):
        el = item.find(f"{{{SPARKLE_NS}}}version")
        return int(el.text) if el is not None and el.text.strip().isdigit() else -1

    items = [i for i in root.findall("channel/item") if build(i) >= 0]
    if not items:
        print("appcast has no items with a sparkle:version", file=sys.stderr)
        return 1

    enclosure = max(items, key=build).find("enclosure")
    if enclosure is None or not enclosure.get("url"):
        print("the newest item has no enclosure URL", file=sys.stderr)
        return 1

    print(enclosure.get("url"))
    return 0


if __name__ == "__main__":
    sys.exit(main())

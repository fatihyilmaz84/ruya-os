#!/usr/bin/env python3
"""Builds the bootc-image-builder config for the installer ISO (called by make-disk.sh).

usage: bib-iso-config.py <chosen config.toml> <image/bib/iso-kickstart.toml> <output config>

bootc-image-builder refuses generated users ([[customizations.user]], used for the dev SSH key)
next to a user-supplied kickstart ("kickstart users and/or groups are not compatible with
user-supplied kickstart content"). So the user blocks are dropped here and the root key they
carried goes into the kickstart itself (rootpw --lock + sshkey), in place of the marker line
`# @ROOT_KEY@` of the kickstart snippet. A config without a key gives a kickstart without one.
"""
import re
import sys


def main() -> int:
    config_path, snippet_path, out_path = sys.argv[1:4]
    config = open(config_path, encoding="utf-8").read()
    snippet = open(snippet_path, encoding="utf-8").read()

    # Split into blocks at table headers ("[x]" or "[[x]]" at the start of a line).
    parts = re.split(r"(?m)^(?=\[)", config)
    keep, keys = [], []
    for part in parts:
        if part.startswith("[[customizations.user]]"):
            user = re.search(r'(?m)^\s*name\s*=\s*"([^"]+)"', part)
            key = re.search(r'(?m)^\s*key\s*=\s*"([^"]+)"', part)
            if user and key and user.group(1) == "root":
                keys.append(key.group(1))
            continue
        keep.append(part)

    lines = ["rootpw --lock"]
    for key in keys:
        if '"' in key or "\n" in key:
            print("bib-iso-config: unusable key", file=sys.stderr)
            return 1
        lines.append('sshkey --username=root "%s"' % key)
    marker = "# @ROOT_KEY@"
    if marker not in snippet:
        print("bib-iso-config: marker missing in " + snippet_path, file=sys.stderr)
        return 1
    snippet = snippet.replace(marker, "\n".join(lines))

    with open(out_path, "w", encoding="utf-8", newline="\n") as out:
        out.write("".join(keep).rstrip("\n") + "\n\n" + snippet)
    print("bib-iso-config: %d root key(s) moved into the kickstart" % len(keys))
    return 0


if __name__ == "__main__":
    sys.exit(main())

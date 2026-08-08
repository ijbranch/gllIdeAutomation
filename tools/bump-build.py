"""Increment the project's build number.

usage: python tools/bump-build.py [version.rc] [--show]

The version lives in exactly one file, gllIdeAutomationVersion.rc, and this edits that file.

It was not always so. Delphi's own mechanism - the VerInfo_* properties in the .dproj - cannot be
reduced to a single definition: there is a Base copy and one per build configuration, and deleting
the per-configuration copy only makes the next build of that configuration write it back. The IDE
then advances FileVersion in that copy on Build while leaving ProductVersion behind, so the two
strings in a shipped BPL can disagree. The .dproj now sets VerInfo_IncludeVerInfo=false and the
resource script is the only source of the version.

Inside the .rc the number still appears twice, because a VERSIONINFO resource needs it both as a
comma-separated numeric tuple (FILEVERSION) and as a display string (VALUE "FileVersion"). They sit
adjacent in one define block, and this script rewrites both together so they cannot drift.
"""
import re
import sys

DEFAULT_RC = "gllIdeAutomationVersion.rc"

FIELDS = ("VER_MAJOR", "VER_MINOR", "VER_RELEASE", "VER_BUILD")


def read(path):
    # newline='' so the CRLF endings already in the file survive the round trip.
    with open(path, encoding="utf-8", newline="") as f:
        return f.read()


def write(path, text):
    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write(text)


def define(text, name):
    """The value of a #define, or None when it is missing."""
    # \r? before $, because in MULTILINE the anchor sits after the CR of a CRLF ending: match it
    # explicitly, and on substitution keep it in a group so the ending is not rewritten to LF.
    m = re.search(r"^#define[ \t]+%s[ \t]+(\d+)[ \t]*\r?$" % name, text, re.MULTILINE)
    return int(m.group(1)) if m else None


def version_string(text):
    """The VER_STRING literal, without its trailing NUL escape."""
    m = re.search(r'^#define[ \t]+VER_STRING[ \t]+"([\d.]+)\\0"[ \t]*\r?$', text, re.MULTILINE)
    return m.group(1) if m else None


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    path = args[0] if args else DEFAULT_RC
    show_only = "--show" in sys.argv

    try:
        text = read(path)
    except OSError as e:
        print(f"cannot read {path}: {e}")
        return 2

    parts = [define(text, f) for f in FIELDS]
    if any(p is None for p in parts):
        missing = [f for f, p in zip(FIELDS, parts) if p is None]
        print(f"{path} is missing: {', '.join(missing)}")
        return 1

    major, minor, release, build = parts
    current = f"{major}.{minor}.{release}.{build}"

    # The tuple and the display string are meant to agree. If they do not, say so rather than
    # quietly picking one - a disagreement here is the exact fault this file exists to prevent.
    declared = version_string(text)
    if declared is None:
        print('no #define VER_STRING "n.n.n.n\\0" found')
        return 1
    if declared != current:
        print(f"WARNING: VER_STRING is {declared} but the numeric defines say {current}")

    if show_only:
        print(current)
        return 0

    new_build = build + 1
    version = f"{major}.{minor}.{release}.{new_build}"

    text, n = re.subn(r"^(#define[ \t]+VER_BUILD[ \t]+)\d+([ \t]*\r?)$",
                      lambda m: f"{m.group(1)}{new_build}{m.group(2)}", text, flags=re.MULTILINE)
    text, s = re.subn(r'^(#define[ \t]+VER_STRING[ \t]+")[\d.]+(\\0"[ \t]*\r?)$',
                      lambda m: f"{m.group(1)}{version}{m.group(2)}", text, flags=re.MULTILINE)

    if n != 1 or s != 1:
        print(f"refusing to write: matched {n} VER_BUILD and {s} VER_STRING, expected 1 of each")
        return 1

    write(path, text)
    print(f"{current}  ->  {version}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

"""Increment the project's build number.

usage: python tools/bump-build.py [project.dproj] [--show]

The IDE increments the build number itself when `VerInfo_AutoIncVersion` is true — but only on
**Build**, not Compile, and only from inside the IDE. MSBuild ignores the setting entirely, so a
command-line or CI build would otherwise stamp the same number forever. Run this first in those
builds.

It updates BOTH places Delphi keeps the number, which is the thing people get wrong:

  <VerInfo_Build>            the numeric field the version resource is built from
  FileVersion=  /  ProductVersion=   inside <VerInfo_Keys>, the displayed strings

Let those disagree and the file's Details tab shows one version while the resource carries
another — which is worse than not versioning at all, because it looks authoritative.

Both live in the .dproj more than once: there is a Base copy, and MSBuild materialises a further
copy per build configuration the first time it builds one. Every occurrence is rewritten, because
the one that gets compiled is whichever config you happen to build.
"""
import re
import sys

DEFAULT_PROJECT = "gllIdeAutomation.dproj"


def read(path):
    # newline='' so the CRLF endings already in the file survive the round trip. Without it,
    # Python's universal-newline translation hands back '\n' and the file is rewritten LF-only.
    with open(path, encoding="utf-8", newline="") as f:
        return f.read()


def write(path, text):
    # newline='' again, so nothing is translated on the way out either. Any BOM is carried
    # through as an ordinary character, which keeps the file byte-identical apart from the edit.
    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write(text)


def field(text, tag, default="0"):
    """The highest value of <tag> in the file - the copies should agree, but if they have drifted
    the largest is the only safe basis for the next number."""
    found = [int(v) for v in re.findall(rf"<{tag}>(\d+)</{tag}>", text)]
    return max(found) if found else int(default)


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    path = args[0] if args else DEFAULT_PROJECT
    show_only = "--show" in sys.argv

    try:
        text = read(path)
    except OSError as e:
        print(f"cannot read {path}: {e}")
        return 2

    major = field(text, "VerInfo_MajorVer", "1")
    minor = field(text, "VerInfo_MinorVer")
    release = field(text, "VerInfo_Release")
    build = field(text, "VerInfo_Build")

    if show_only:
        print(f"{major}.{minor}.{release}.{build}")
        return 0

    new_build = build + 1
    version = f"{major}.{minor}.{release}.{new_build}"

    # Every occurrence, not just the first: the config-specific copy is the one that gets built.
    text, n = re.subn(r"<VerInfo_Build>\d+</VerInfo_Build>",
                      f"<VerInfo_Build>{new_build}</VerInfo_Build>", text)
    if n == 0:
        print("no <VerInfo_Build> element found - is VerInfo_IncludeVerInfo enabled?")
        return 1

    # Keep the displayed strings in step with the numeric fields.
    text, nf = re.subn(r"FileVersion=\d+\.\d+\.\d+\.\d+", f"FileVersion={version}", text)
    text, np = re.subn(r"ProductVersion=\d+\.\d+\.\d+\.\d+", f"ProductVersion={version}", text)

    write(path, text)
    print(f"{major}.{minor}.{release}.{build}  ->  {version}"
          f"   ({n} VerInfo_Build, {nf} FileVersion, {np} ProductVersion)")
    return 0


if __name__ == "__main__":
    sys.exit(main())

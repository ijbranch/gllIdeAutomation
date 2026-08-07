"""Read a value out of a Delphi IDE debugger pane, as text.

usage: python read_pane.py X Y [--pane locals|watch] [--name]

Selects the row at screen coordinate X,Y, fires the pane's "Copy Value" popup item, and prints
what lands on the clipboard. `--name` copies the name column instead of the value.

Why this exists: `app_get` cannot read Local Variables or the Watch window. Both are
VirtualStringTree, whose cell text is not a published property, so the only structured way out
is the popup menu's own Copy commands. Selecting the row needs a real mouse click, which is
`click.py` -- see the coordinate trap documented there, it is not optional reading.

Talks to the automation server directly over its loopback socket (newline-delimited JSON, token
from the discovery file), so this works with no MCP tooling in the loop.
"""
import ctypes
import glob
import json
import os
import socket
import subprocess
import sys
import time

DISCOVERY_DIR = r"C:\ProgramData\GITLAK\Automation"
APP_NAME = "DelphiIDE"

# Component names read off the live IDE with `app_tree`, not guessed - the two panes do not
# follow the same naming convention, which is exactly the sort of thing that silently returns
# "no value" if you assume symmetry.
PANES = {
    "locals": ("LocalVarsWindow", "lvCopyValue", "lvCopyName"),
    "watch": ("WatchWindow", "CopyWatchValue", "CopyWatchName"),
}


def find_ide():
    """@returns (pid, port, token) for the running IDE, or raises."""
    for path in glob.glob(os.path.join(DISCOVERY_DIR, "*.json")):
        try:
            # utf-8-sig, not utf-8: the server writes the discovery file WITH a BOM, and plain
            # utf-8 leaves it in the stream so json.load throws - which this loop would then
            # swallow, reporting "no IDE running" while the IDE sits there running.
            with open(path, encoding="utf-8-sig") as f:
                d = json.load(f)
        except (OSError, ValueError):
            continue
        if d.get("app") == APP_NAME:
            return d["pid"], d["port"], d["token"]
    raise SystemExit(
        f"No {APP_NAME} in {DISCOVERY_DIR}. Is the IDE running, and was it started with "
        f"GITLAK_IDE_AUTOMATION=1? See tools/Start-IDE.ps1."
    )


def command(port, token, **fields):
    """Send one command to the automation server and return its parsed reply."""
    payload = json.dumps({"token": token, "id": 1, **fields}) + "\n"
    with socket.create_connection(("127.0.0.1", port), timeout=10) as s:
        s.sendall(payload.encode("utf-8"))
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = s.recv(4096)
            if not chunk:
                break
            buf += chunk
    return json.loads(buf.decode("utf-8").strip())


def clipboard():
    out = subprocess.run(["powershell", "-NoProfile", "-Command", "Get-Clipboard"],
                         capture_output=True, text=True)
    return out.stdout.rstrip("\r\n")


def set_clipboard(text):
    subprocess.run(["powershell", "-NoProfile", "-Command", f"Set-Clipboard -Value '{text}'"],
                   capture_output=True)


def main():
    args = sys.argv[1:]
    if len(args) < 2:
        print(__doc__)
        return 2
    x, y = int(args[0]), int(args[1])
    pane = args[args.index("--pane") + 1] if "--pane" in args else "locals"
    if pane not in PANES:
        print(f"unknown pane '{pane}' - expected one of {', '.join(PANES)}")
        return 2
    form, value_item, name_item = PANES[pane]
    item = name_item if "--name" in args else value_item

    pid, port, token = find_ide()

    here = os.path.dirname(os.path.abspath(__file__))
    click = subprocess.run([sys.executable, os.path.join(here, "click.py"),
                            str(x), str(y), "--activate", str(pid)],
                           capture_output=True, text=True)
    if click.returncode != 0:
        print(click.stdout.strip() or "click failed")
        return 1

    # A sentinel makes "the handler did nothing" distinguishable from "the value happened to be
    # whatever was already on the clipboard" - which is exactly the confusion that made this
    # route look broken the first time it was tried.
    sentinel = "__GLL_SENTINEL__"
    set_clipboard(sentinel)
    time.sleep(0.1)

    reply = command(port, token, cmd="click", form=form, name=item)
    if not reply.get("ok"):
        print("automation server refused:", json.dumps(reply.get("error", {})))
        return 1

    time.sleep(0.25)
    got = clipboard()
    if got == sentinel:
        print(f"NO VALUE - {item} fired but wrote nothing. Almost always means no row is "
              f"selected: check that ({x},{y}) is really over a row in {form}.")
        return 1

    print(got)
    return 0


if __name__ == "__main__":
    sys.exit(main())

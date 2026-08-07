"""Click at a screen coordinate, in the same coordinate space as our screenshots.

usage: python click.py X Y [--double] [--right] [--activate PID]

Two traps, both learned the hard way on this machine:

1. DISPLAY SCALING. Ian runs 150%, so the physical desktop is 7680x2160 while a DPI-unaware
   process - which is what python.exe and the screen-capturing PowerShell both are - sees a
   virtualised 5120x1440. SetCursorPos and GetSystemMetrics are virtualised to match, and so are
   the screenshots. SendInput's MOUSEEVENTF_ABSOLUTE coordinates are NOT: they are physical.
   Normalising against the virtualised metrics therefore lands every click at two thirds of the
   intended position. So: position with SetCursorPos (virtualised, matches the screenshots) and
   send the button events with no coordinates at all.

2. A HUMAN USING THE MOUSE. Bare button events apply wherever the cursor is at that instant. If
   someone moves the mouse between the move and the click, the click lands in their window. So
   verify the cursor actually sits where we put it, immediately before clicking, and abort
   rather than click blind.
"""
import ctypes
import subprocess
import sys
import time
from ctypes import wintypes

user32 = ctypes.WinDLL("user32", use_last_error=True)

# MUST happen before any cursor call. Measured on this machine: two 4K monitors at 150%, so the
# physical desktop is 7680x2160 and the DPI-unaware view is 5120x1440. SetCursorPos from an
# UNAWARE process takes virtualised coordinates (verified: asking for 1000,500 lands at physical
# 1500,750), but CopyFromScreen returns PHYSICAL pixels - the left monitor occupies 3840 of a
# 5120-wide capture, which is a crop, not a scale. Those two spaces differ by exactly 1.5, which
# is why every click landed two thirds of the way to its target. Declaring per-monitor awareness
# puts SetCursorPos into physical coordinates, so it matches the screenshots 1:1.
user32.SetProcessDpiAwarenessContext(ctypes.c_void_p(-4))   # PER_MONITOR_AWARE_V2

MOUSEEVENTF_LEFTDOWN = 0x0002
MOUSEEVENTF_LEFTUP = 0x0004
MOUSEEVENTF_RIGHTDOWN = 0x0008
MOUSEEVENTF_RIGHTUP = 0x0010

TOLERANCE = 2   # pixels of drift we will accept before calling it a human's mouse


def cursor():
    p = wintypes.POINT()
    user32.GetCursorPos(ctypes.byref(p))
    return p.x, p.y


def place(x, y, attempts=3):
    """Put the cursor at x,y and confirm it stayed. Returns True if it did."""
    for _ in range(attempts):
        user32.SetCursorPos(x, y)
        time.sleep(0.12)
        cx, cy = cursor()
        if abs(cx - x) <= TOLERANCE and abs(cy - y) <= TOLERANCE:
            return True
    return False


def main():
    args = sys.argv[1:]
    if len(args) < 2:
        print(__doc__)
        return 2
    x, y = int(args[0]), int(args[1])
    double, right = "--double" in args, "--right" in args

    if "--activate" in args:
        pid = args[args.index("--activate") + 1]
        subprocess.run(["powershell", "-NoProfile", "-Command",
                        f"(New-Object -ComObject WScript.Shell).AppActivate({pid})"],
                       capture_output=True)
        time.sleep(0.8)

    old = cursor()

    if not place(x, y):
        print(f"ABORTED: cursor will not stay at ({x},{y}) - it reads {cursor()}. "
              f"Someone is using the mouse; not clicking blind.")
        return 1

    down = MOUSEEVENTF_RIGHTDOWN if right else MOUSEEVENTF_LEFTDOWN
    up = MOUSEEVENTF_RIGHTUP if right else MOUSEEVENTF_LEFTUP

    for _ in range(2 if double else 1):
        # Re-verify immediately before each press: the check above is worthless if the pointer
        # moves in the intervening milliseconds.
        cx, cy = cursor()
        if abs(cx - x) > TOLERANCE or abs(cy - y) > TOLERANCE:
            print(f"ABORTED mid-click: cursor drifted to ({cx},{cy})")
            return 1
        user32.mouse_event(down, 0, 0, 0, 0)
        time.sleep(0.06)
        user32.mouse_event(up, 0, 0, 0, 0)
        time.sleep(0.08)

    time.sleep(0.3)
    user32.SetCursorPos(*old)
    print(f"clicked ({x},{y}); cursor returned to {old}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

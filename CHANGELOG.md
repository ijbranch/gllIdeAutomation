# Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- Initial package: starts `TAutomationServer` from GITLAKLib inside the Delphi 13 IDE, so the
  `app_*` agent tools can drive the IDE through the live VCL component model instead of
  synthesising keystrokes. **Why:** IDE-side behaviour — whether a debug visualizer is offered,
  how a value renders — is invisible to the compiler, and driving the IDE by `SendKeys` plus
  screenshots is slow, expensive in context, and carries a standing risk of typing into the
  wrong window. The server was already compiled into `GITLAKLib370.bpl` and already loaded by
  the IDE; nobody was calling `Start`. (2026-08-08) — `u_gllIdeAutomationStarter.pas`,
  `gllIdeAutomation.dpk`, `gllIdeAutomation.dproj`
- `tools/click.py` — clicks at a screen coordinate, which is what makes debugger panes readable.
  Select a row with it, fire `lvCopyValue` through `app_click`, read the clipboard: the value
  arrives as text. Verified on two rows against what the pane displayed. **Why it needs care:**
  with two 4K monitors at 150%, screenshots come back in *physical* pixels (`CopyFromScreen`
  crops, it does not scale) while `SetCursorPos` in a DPI-unaware process takes *virtualised*
  ones — a factor of exactly 1.5, so a coordinate read off a screenshot lands two thirds of the
  way to its target and `SendInput` still reports success. The tool declares
  `PER_MONITOR_AWARE_V2` so both spaces are physical, and refuses to click if the cursor will not
  stay put, so a human using the mouse does not receive the click. (2026-08-08) — `tools/click.py`
- Gated on the `GITLAK_IDE_AUTOMATION=1` environment variable, so an IDE launched any other way
  is unaffected. **Why not `/AUTOMATION`,** as the DBi apps use: `bds.exe` parses its own command
  line and treats unrecognised arguments as files to open. (2026-08-08) —
  `u_gllIdeAutomationStarter.pas`

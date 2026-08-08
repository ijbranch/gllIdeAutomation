# Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- Initial package: starts the automation server inside the Delphi IDE, so external agent tools can drive the IDE through the live VCL component model instead of
  synthesising keystrokes. **Why:** IDE-side behaviour — whether a debug visualizer is offered,
  how a value renders — is invisible to the compiler, and driving the IDE by `SendKeys` plus
  screenshots is slow, expensive in context, and carries a standing risk of typing into the
  wrong window. The server unit already existed for driving VCL applications under test; nobody was calling
  `Start` inside the IDE. (2026-08-08) — `u_gllIdeAutomationStarter.pas`,
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
  is unaffected. **Why not a command-line switch:** `bds.exe` parses its own command
  line and treats unrecognised arguments as files to open. (2026-08-08) —
  `u_gllIdeAutomationStarter.pas`
- Version information on the BPL, starting at 1.0.0.1, with `VerInfo_AutoIncVersion` so the IDE
  advances it on each Build. **Why:** the BPL is installed into a shared IDE, so when one
  misbehaves the first question is which build is loaded — and an unversioned DLL cannot answer
  it. Documented with the one-line command that reads it back. (2026-08-08) —
  `gllIdeAutomation.dproj`, `gllIdeAutomation.res`, `README.md`, `docs/HELP.md`,
  `docs/Users Guide.md`
- `tools/bump-build.py` — increments the build number from the command line. **Why:**
  `VerInfo_AutoIncVersion` is honoured by the IDE on Build only; MSBuild ignores it, so a
  command-line or CI build stamps the same number forever (verified here — two consecutive
  `build_project` runs left the number at 1). It rewrites every copy of both the numeric
  `<VerInfo_Build>` and the `FileVersion=`/`ProductVersion=` strings, since MSBuild materialises a
  further copy of each per build configuration and the one that gets compiled is whichever config
  you build. (2026-08-08) — `tools/bump-build.py`, `README.md`, `docs/HELP.md`,
  `docs/Users Guide.md`
- `$LIBSUFFIX` is now chosen by `CompilerVersion`, so the package builds on 10.3 Rio through 13
  Florence rather than 12 and later only. **Why:** `{$LIBSUFFIX AUTO}` is itself a 12-and-later
  feature, so on an older IDE the directive that was meant to supply the suffix was the thing that
  broke the build. Anything older than 10.3 stops with a `{$MESSAGE FATAL}` naming the requirement
  instead of failing obscurely further in. (2026-08-08) — `gllIdeAutomation.dpk`, `README.md`

### Changed

- `<ProjectVersion>` lowered to 18.8 so older IDEs will open the project rather than refuse it,
  matching the compiler range the `$LIBSUFFIX` conditional now covers. (2026-08-08) —
  `gllIdeAutomation.dproj`
- The `.dproj` is reindented to two spaces and carries a BOM — a one-time normalisation MSBuild
  applied on first build, not a hand edit. Rebuilding is now byte-idempotent. (2026-08-08) —
  `gllIdeAutomation.dproj`

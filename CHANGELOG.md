# Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [In-Service]

> Libraries and packages are continuously deployed: changes below are live as soon as the package is rebuilt and installed - there is no separate release step, so no `[Unreleased]` backlog. Tagged version snapshots are listed beneath.

### Fixed- **C++Builder output turned off** (2026-08-26). `DCC_CBuilderOutput` was `All`, so every build emitted `.hpp` / `.bpi` / `.a` / `.obj` files for a compiler that is **never in scope here** (standing rule: "I dont use C++ at all"). Across the estate that was 616 files and 90 MB of output nobody consumes, regenerated on every build; `gllSynEdit` alone accounted for 560. Now `None`. The `DCC_HppOutput` / `DCC_BpiOutput` / `DCC_ObjOutput` properties are left in place deliberately - they only say *where* such files would go, so with generation off they are inert, and removing them would enlarge the diff without changing behaviour. Verified: the affected packages rebuilt clean in every enabled mode, emitted no C++ artefacts, and rebuilt clean again after the existing ones were deleted (so nothing was load-bearing).



- Debug and Release package output no longer collide (2026-08-24)
  **Why:** RAD Studio defaults `DCC_BplOutput` to `$(BDSCOMMONDIR)\Bpl\$(Platform)` and `DCC_DcpOutput` to `\Dcp\$(Platform)`, neither carrying `$(Config)`, so whichever configuration was built last was the one left installed. `.dcu` output was already separated, which masked it.
  Release still writes to the shared `Bpl`/`Dcp` folders - that is what is on `PATH`, and it is where dependent packages resolve their `requires` from - while Debug is diverted to a `$(Config)` subfolder. Separating Release as well breaks package loading, so only Debug moves.
  Verified by building the package in both configurations.

### Added

- Documented that a build fails with two `F2039 Could not create output file` errors when an IDE
  has the package installed, because it holds both the `.bpl` and the `.dcp` open — and that this
  applies to command-line builds too, not just builds from inside the IDE. **Why:** it is the
  first wall anyone changing the source hits, the error text does not mention the cause, and the
  error *count* is the diagnostic. Reproduced twice. (2026-08-08) — `docs/HELP.md`, `README.md`

## [1.0.1] - 2026-08-08

The release the announcement points at. Delphi 13 Florence, Win32 or Win64, MIT licensed.

### Added

- Initial package: starts the automation server inside the Delphi IDE, so external agent tools can drive the IDE through the live VCL component model instead of
  synthesising keystrokes. **Why:** IDE-side behaviour — whether a debug visualizer is offered,
  how a value renders — is invisible to the compiler, and driving the IDE by `SendKeys` plus
  screenshots is slow, expensive in context, and carries a standing risk of typing into the
  wrong window. The server unit already existed for driving VCL applications under test; nobody was calling
  `Start` inside the IDE. (2026-08-08) — `src/gllIdeAutomation.Starter.pas`,
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
  `src/gllIdeAutomation.Starter.pas`
- Version information on the BPL, defined once in `gllIdeAutomationVersion.rc` and linked by the
  `.dpk`. **Why:** the BPL is installed into a shared IDE, so when one misbehaves the first
  question is which build is loaded — and an unversioned DLL cannot answer it. Documented with the
  one-line command that reads it back. (2026-08-08) — `gllIdeAutomationVersion.rc`,
  `gllIdeAutomation.dpk`, `gllIdeAutomation.dproj`, `README.md`, `docs/HELP.md`,
  `docs/Users Guide.md`
- `tools/bump-build.py` — increments the build number in the `.rc`, rewriting the numeric
  `VER_BUILD` and the display `VER_STRING` together so they cannot drift, and refusing to write
  unless it matched exactly one of each. (2026-08-08) — `tools/bump-build.py`, `README.md`,
  `docs/HELP.md`, `docs/Users Guide.md`
- `$LIBSUFFIX` is now chosen by `CompilerVersion`, so the package builds on 10.3 Rio through 13
  Florence rather than 12 and later only. **Why:** `{$LIBSUFFIX AUTO}` is itself a 12-and-later
  feature, so on an older IDE the directive that was meant to supply the suffix was the thing that
  broke the build. Anything older than 10.3 stops with a `{$MESSAGE FATAL}` naming the requirement
  instead of failing obscurely further in. (2026-08-08) — `gllIdeAutomation.dpk`, `README.md`
- `gllIdeAutomation.diproj` — the DocInsight project that builds the API documentation from the
  units' XML doc comments. It carries only relative paths, so it works from any clone. The
  generated `build/docs` output is not tracked. (2026-08-08) — `gllIdeAutomation.diproj`,
  `.gitignore`, `README.md`

### Changed

- The version moved out of the `.dproj`'s `VerInfo_*` properties and into a resource script,
  `gllIdeAutomationVersion.rc`, with `VerInfo_IncludeVerInfo=false`. **Why:** Delphi's mechanism
  cannot be reduced to one definition — the `.dproj` keeps a Base copy plus one per build
  configuration, and deleting the per-configuration copy only makes the next build of that
  configuration write it back, byte for byte. The IDE's auto-increment then advances `FileVersion`
  in that copy on Build while leaving `ProductVersion` behind, so the facility meant to manage the
  version is itself capable of shipping a BPL whose two version strings disagree. Verified after
  the move: building both configurations regenerates nothing, and exactly one file in the repo
  defines a version. (2026-08-08) — `gllIdeAutomationVersion.rc`, `gllIdeAutomation.dpk`,
  `gllIdeAutomation.dproj`, `.gitignore`
- `tools/Start-IDE.ps1` finds the IDE in the registry (`Software\Embarcadero\BDS\<ver>\RootDir`,
  HKCU then HKLM) instead of hard-coding one install path, preferring `bin64\bds.exe` where a
  version ships one. `-Version` and `-BdsPath` override it. **Why:** the path it hard-coded was
  13 Florence's, so on any other IDE the first script a new user runs threw — while the README
  offered 10.3 Rio and later. When the server fails to start it now names the BPL and the
  `Known Packages` key for the IDE that was actually launched. (2026-08-08) — `tools/Start-IDE.ps1`,
  `README.md`
- The supported range is stated as targeted rather than tested: 13 Florence is the only version
  the package has been built on. **Why:** an ambitious claim a stranger disproves in five minutes
  costs more than an honest one, and the 10.3–12 `$LIBSUFFIX` branches have never been
  exercised. (2026-08-08) — `README.md`
- Older IDEs are supported through the `.dpk` rather than through the `.dproj`. `<ProjectVersion>`
  was briefly lowered to 18.8 so an older IDE would open the project; that was abandoned because
  13 Florence rewrites it to 20.5 on every open, so the setting had to be reverted after each IDE
  session to stay committed. **Why this way instead:** the `.dpk` is the actual project and is
  version-agnostic — verified by compiling it with `dcc64` and no `.dproj` present at all, which
  produced a correct, correctly-versioned BPL. A `.dproj` is only the MSBuild wrapper belonging to
  whichever IDE wrote it, so an older IDE generates its own. Separate per-version project files
  were considered and rejected: five copies of the same settings would drift, and only the 13
  Florence one could be tested here. (2026-08-08) — `gllIdeAutomation.dproj`, `README.md`,
  `docs/Users Guide.md`
- The `.dproj` now holds whatever 13 Florence writes — `ProjectVersion` 20.5, the Win64x platform,
  a `DCCReference` to the generated version resource, four-space indentation. It is treated as the
  IDE's file rather than a hand-maintained one, so opening the project no longer produces a diff
  to revert. A fresh checkout still builds: MSBuild compiles the `.rc` before resolving the
  reference to its output. (2026-08-08) — `gllIdeAutomation.dproj`

### Fixed

- Three illegal control characters in the starter unit's doc comment, which stopped DocInsight
  transforming the topic to HTML (`0xC00CE508: An invalid character was found in text content`).
  The example path had been written through a layer that interprets C escape sequences, so
  `\37` became octal `0x1F` and each `\b` a backspace `0x08` — `Studio\37.0\bin64\bds.exe` was
  stored as `Studio·.0·in64·ds.exe`. The other backslashes survived only because `\P`, `\E` and
  `\S` are not escape sequences. **Why it went unnoticed:** control characters are invisible in an
  editor and legal in Pascal comments, so the package compiled clean throughout — nothing but an
  XML parser was ever going to object. All four doc blocks now parse as XML, and no tracked text
  file contains a character below 0x20 other than tab, CR or LF. (2026-08-08) —
  `src/gllIdeAutomation.Starter.pas`
- The two entries above naming the starter unit called it `u_gllIdeAutomationStarter.pas`, which
  has never existed here — it is `src/gllIdeAutomation.Starter.pas`. (2026-08-08) —
  `CHANGELOG.md`
- The docs said MSBuild "ignores" `VerInfo_AutoIncVersion`. It does not ignore it — it tries and
  fails, which is only visible below the default MSBuild verbosity. Right outcome, wrong reason,
  in four places. (2026-08-08) — `README.md`, `docs/HELP.md`, `docs/Users Guide.md`,
  `tools/bump-build.py`
- The note on why every copy of the version is rewritten now records two things that were
  measured rather than assumed: the per-configuration copy cannot be removed — delete it and the
  next build of that configuration writes it back, byte for byte — and the IDE's own
  auto-increment advances `FileVersion` while leaving `ProductVersion` behind, so a Build from
  the IDE is by itself enough to produce a BPL whose two version strings disagree. (2026-08-08) —
  `tools/bump-build.py`

## [1.0.0] - 2026-08-08

Tagged before the fixes above and superseded within the day — **use 1.0.1**. It carried no version
information on the BPL, a `tools/Start-IDE.ps1` hard-coded to one Delphi install path, and three
invisible control characters in a doc comment that stopped the documentation building. Left in
place rather than moved, because it was already published and genuinely was that code.

[Unreleased]: https://codeberg.org/GITLAK/gllIdeAutomation/compare/v1.0.1...main
[1.0.1]: https://codeberg.org/GITLAK/gllIdeAutomation/src/tag/v1.0.1
[1.0.0]: https://codeberg.org/GITLAK/gllIdeAutomation/src/tag/v1.0.0

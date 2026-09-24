# Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- **`tree_text` reads the debugger panes: Local Variables, Watch and Call Stack** (2026-09-25) —
  `src\gllIdeAutomation.TreeText.pas`, `src\gllIdeAutomation.Server.pas`, `gllIdeAutomation.dpk`,
  `gllIdeAutomation.dproj`, `Help.md`, `README.md`, `Users Guide.md`. `get` could never reach them:
  a `TVirtualStringTree` holds no text and asks its `OnGetText` handler for each cell as it paints,
  so the only route was `tools\read_pane.py`, one row per real mouse click at screen coordinates.
  `tree_text` stands in front of `OnGetText` for one read, walks the tree a page at a time so every
  displayed row paints, records what the real handler answers, then restores the handler and the
  scroll position. It returns `{ level, cells }` per row, the header captions, the tree's own
  `rootCount`, and `complete` with a note whenever that is false. Before hooking, it checks the
  event's signature against RTTI and refuses with `SignatureMismatch` rather than risk an access
  violation inside the IDE's paint. That check caught a real mismatch on the first live run: the 64-bit
  IDE's VirtualTrees passes the cell text as `var WideString`, not `var string`, so the reader now
  installs whichever of the two handler shapes RTTI reports. Five new error codes: `NotVirtualTree`, `NoWindow`,
  `NotOnScreen`, `NoGetText`, `SignatureMismatch`. Measured against the running IDE first: all
  three panes are plain `TVirtualStringTree` with `OnGetText`, not IDE subclasses that could supply
  text some other way. **The technique is Thomas Mueller's**, from `TREETEXT` in GxInspect, the
  GExperts inspection server; this is a re-implementation, credited in the unit header. Fork-only:
  nothing goes back to GITLAKLib, whose applications carry no virtual tree. **Built in four modes
  with zero hints. Verified live in the 64-bit IDE:** all three panes hooked and restored with the
  IDE responsive throughout. It read header captions (`Name`/`Value`, `Watch Name`/`Value`) and
  real cell text (the Call Stack's "Process is not accessible", 23 of 23 rows in 17 ms), and
  reported empty panes as `complete` with no rows. **Not yet proven:** reading frames and locals from
  a paused debugger, and node levels through `GetNodeLevel`, because in every live run the program
  was still running.

- **`ping`/`info` reports `package`, this package's OWN version** (2026-09-21) —
  `src\gllIdeAutomation.Server.pas`, `Help.md`. `version` has always been `ParamStr( 0 )`'s, which
  inside the IDE is `bds.exe`'s — measured on the live IDE, `37.0.60952.8797`. So the single-source
  version in `gllIdeAutomationVersion.rc`, and the whole `VerInfo_IncludeVerInfo=false` apparatus
  that exists to keep it single, could not be read at run time at all: there was no way to tell
  which build of `gllIdeAutomation` an IDE had loaded. `GetPackageFileVersion` reads the version
  resource of `HInstance`, which in a package is the BPL itself. Verified live: `"package":"1.1.0.0"`
  alongside `"version":"37.0.60952.8797"`. **Carry back to GITLAKLib.**
- **Stale discovery files are swept at startup** (2026-09-21) —
  `src\gllIdeAutomation.Server.pas`, `Help.md`. `DeleteDiscovery` runs only on an orderly shutdown,
  so a host that was killed or crashed left its `<pid>.json` advertisement behind for ever.
  Consumers take the **first** file whose `app` matches — `tools/read_pane.py` does exactly that —
  so a single corpse is enough to make a running IDE look unreachable. `SweepStaleDiscovery` now
  deletes any `<pid>.json` whose process is gone; a PID that has since been reused reads as alive
  and is kept, which errs towards keeping a stale file rather than deleting a live one.
  Verified twice against a live IDE, once with a planted `999123.json` and once with a genuine
  leftover from a previous run. **Carry back to GITLAKLib.**
- **A request-line size limit, and the `RequestTooLong` error code** (2026-09-21) —
  `src\gllIdeAutomation.Server.pas`, `Help.md`. Indy's default `MaxLineAction` is `maSplit`, which
  silently cuts an over-long request in two: the first half fails to parse as JSON and the second
  half is then dispatched **as if it were a separate request**. `MAX_REQUEST_BYTES` (1 MB) plus
  `maException` makes that a diagnosable failure instead. The reply is written before the
  connection is dropped, because the remainder of the line is still buffered and anything read
  from it would be a fragment masquerading as the next request. Verified with a 2 MB line.
  **Carry back to GITLAKLib.**

- **`Help.md` and `Users Guide.md`, to the estate documentation standard** (2026-09-18).
  `Help.md` carries both flavours: the Pascal surface is tiny (`TAutomationServer.Start` /
  `Stop` / `IsRunning` / `Port`), but the API people actually write against is the **wire
  protocol** — 13 commands, a fixed argument vocabulary and 23 stable error codes — which is a
  lookup table by any measure, plus failures by symptom since the package is consumed as-is.
  `Users Guide.md` is task-ordered: start the gated IDE, connect, read a form, drive a control.
  **The two structural limits are documented with their mechanism**, not just asserted: `get`
  reads published properties through RTTI and `TVirtualStringTree` publishes neither cell text
  nor selection, so debugger-pane *contents* are unreachable; and `AutoCmdTree` enumerates forms
  then each form's **owned** components one level deep, so an add-in frame is out of reach — for
  which the process module list is the way to prove a BPL loaded.
  §3 records the real divergence here: `src\gllIdeAutomation.Server.pas` is **vendored** from
  GITLAKLib's `gllAutomationServer` and deliberately renamed, because a Delphi unit may exist in
  only one loaded package — and nothing keeps the two copies in step.

### Fixed

- **The vendored body was 283 lines and one wire version behind GITLAKLib, with two live bugs;
  re-synced from `gllAutomationServer` 0.8** (2026-09-21) — `src\gllIdeAutomation.Server.pas`.
  The unit header asserted the body was "unchanged - only this header, the unit name and one
  exception message differ". It was not: this copy sat at `SERVER_VERSION` **0.7** against
  upstream's **0.8**, 1425 lines against 1709. Nothing keeps the two in step and nothing had.
  The two that were **defects, not missing features**:
  - **The port-scan `except` was bare here.** Upstream narrowed it to `on EIdException do ;` so
    that a genuine fault — an access violation, a bad configuration — is no longer disguised as a
    busy port and retried silently against 200 addresses, leaving only the misleading
    `no free loopback port in range`. That narrowing had never been carried across.
  - **A `dialogs` click could not dismiss a styled button, and reported success anyway.** A
    custom-drawn control keeps a window class containing `button`, so the search finds it, but its
    window procedure does not implement `BM_CLICK` — the send succeeds while nothing happens.
    Upstream falls back to `WM_LBUTTONDOWN`/`WM_LBUTTONUP` at the client-rect centre, then polls
    `IsWindow` for up to `DISMISS_WAIT_MS` and reports `dismissed`. **This one matters most
    precisely here**, because the host is `bds.exe`, which is full of styled dialogs.
  Also brought across: `click` `count` / `clicksDispatched` / `stoppedReason`, `set` `previous` /
  `changed`, and `NoProp` carrying the object's property surface in `error.data`. All three
  verified against the live IDE — `previous:"Delphi 13 (64-bit)"`, and a `NoProp` reply listing 59
  properties with `total` / `truncated`.
  The header now says what actually diverges, and every fork-only change is marked `FORK` in the
  source so the next re-sync can find them. `Help.md` §4 and `README.md`'s Provenance section
  repeated the old "unchanged body" claim — §4 asserted it in the very words the unit header now
  forbids, and README said driving the IDE "turned out to need no changes at all" — so both were
  rewritten to describe the divergence and point at the `FORK` markers. The re-sync itself is a
  separate commit, deliberately, so a future merge can diff against exactly the upstream state.
- **A wrongly typed envelope field dropped the connection with no reply** (2026-09-21) —
  `src\gllIdeAutomation.Server.pas`, `Help.md`. `GetValue<T>` routes to `TJSONValue.AsType<T>`,
  which **raises** when a field is present but of the wrong type — `{"id":"abc"}` was enough. Both
  envelope reads sat outside `ExecuteCommand`'s own `try`, so the raise escaped with the response
  object already allocated (leaking it), was re-raised on the Indy worker by `TThread.Synchronize`,
  passed the `try..finally` in `HandleLine`, and reached Indy, which closed the socket. The caller
  saw a dropped connection rather than an error, which reads as the server having crashed.
  `DisableIdleTimers`, being inside the marshalled block but outside any handler, had the same
  reach. Now: `TryGetValue` for the envelope, a broad-but-**reported** handler around the
  marshalled call, and every reply carries the `id`. Verified live — four previously fatal
  requests (`id` a string, `cmd` an object, `token` a number, a bad token) all now answer, and the
  probe reports **0 dropped connections**. **Carry back to GITLAKLib.**
- **The discovery directory is created with a restricted DACL** (2026-09-21) —
  `src\gllIdeAutomation.Server.pas`, `Help.md`. The discovery file holds the session token, which
  is the only thing between a local user and a server that can drive the UI and write datasets —
  and the code asserted nothing about its permissions. Measured: `C:\ProgramData` grants
  `BUILTIN\Users` `ReadAndExecute`, inherited by `C:\ProgramData\GITLAK`, so a directory created
  with `TDirectory.CreateDirectory` hands the token to every account on the machine. (The live
  folder on this machine happened to have had its inheritance broken **out of band** — nothing in
  this repository did that, and deleting the folder would have lost it.) `EnsureDiscoveryDir` now
  creates the leaf with a protected DACL naming only `SYSTEM`, `BUILTIN\Administrators` and the
  host's own account. An **existing** directory is deliberately left alone — it is shared with the
  rest of the GITLAK tooling — and a failed hardening still creates the directory but says so
  through `OutputDebugString` instead of passing silently. The SDDL was verified to produce
  exactly that ACL, with the current user still able to write. **Carry back to GITLAKLib.**
- **The screenshot path assumed `%USERPROFILE%\Desktop`** (2026-09-21) —
  `src\gllIdeAutomation.Server.pas`. The Desktop is routinely redirected (OneDrive does it by
  default), and the failure was not a miss but something worse: `CaptureRect` calls
  `ForceDirectories`, so the old path would **create** a second, empty `%USERPROFILE%\Desktop` and
  drop the PNG into a folder the user never opens, while reporting success. Now resolved through
  `SHGetKnownFolderPath( FOLDERID_Desktop )`, falling back to the old path only if that fails.
  `GetTickCount64` replaces `GetTickCount` in the filename, whose 32-bit counter wraps every 49
  days and is the only thing keeping the names apart. Not reproducible on this machine — the
  Desktop here is not redirected — so this is a latent fault fixed on inspection, not a measured
  one. **Carry back to GITLAKLib.**
- **`tree` and `dialogs` leaked their result on an error path** (2026-09-21) —
  `src\gllIdeAutomation.Server.pas`. Both built a `TJSONArray` that nothing owned yet and filled it
  before parenting it, so an exception part-way through — `CompToJSON` reads live published
  properties, and a getter can raise — abandoned the array, while the caller never received the
  object either because the assignment to `Result` had not happened. Both now create and parent
  first, under `try..except oRes.Free; raise;`. Bounded, but this runs inside an IDE that stays
  open for days. **Carry back to GITLAKLib.**
- **`DisableIdleTimers` is no longer called in this host** (2026-09-21) —
  `src\gllIdeAutomation.Server.pas`. Upstream runs it before every VCL command because it drives
  an **application** that may log itself out mid-test. `bds.exe` has no such timeout, so the only
  thing the sweep could achieve here was to reach into a third-party IDE plug-in, set an `Enabled`
  it does not own to `False`, and never put it back — a permanent, unannounced change to the
  user's IDE, made by a tool whose entire job is to observe it. The routine is retained, and
  documented as retained, so the two copies still read alike. **This one is FORK-ONLY — do not
  carry it back**, since it is correct upstream.
- **A bare `CR` inside `CHANGELOG.md` swallowed a heading** (2026-09-21). `### Fixed` and the
  bullet after it were joined by a lone `\r` rather than a `CRLF`, so the whole 2026-08-26
  C++Builder paragraph rendered as one `<h3>`. A repository-wide scan found this to be the only
  such character in any tracked `.md`, `.pas`, `.py`, `.ps1`, `.rc` or project file.
  **This file's line endings are now uniform, and that is most of this commit's `CHANGELOG.md`
  diff.** It was the one tracked file whose *stored* blob carried literal `CRLF` — 188 of them
  against 37 bare `LF`, a mix, which is how a lone `CR` survived unnoticed. Every other file is
  stored as `LF` and converted on checkout by `core.autocrlf=true`. Normalising costs ~180 lines
  of whitespace-only churn once and stops the file being a special case; it is recorded here so
  nobody mistakes it for lost content.
- **`README.md` claimed `Screen.CustomForms`; the code uses `Screen.Forms`** (2026-09-18,
  corrected and actually fixed 2026-09-21) — `README.md`, `Help.md`, `docs/Users Guide.md`.
  `Screen.Forms` is a strict **subset** of `Screen.CustomForms`, so the documents claimed a
  broader reach than the code has. Now corrected at all five sites, including `Help.md`'s
  `requires` table, which contradicted `Help.md`'s own §2 two hundred lines earlier, and
  `docs/Users Guide.md`, which additionally said the walk is over `TControl`/`TWinControl` when
  `CompToJSON` takes a `TComponent`.
  **Two errors in the original entry, both corrected here:** it named the `Starter.pas` docstring
  as a second offender — that unit contains no occurrence of `CustomForms` and never did — and it
  said "all four enumeration sites" when there are **three** `Screen.FormCount` loops
  (`AutoCmdTree` twice over, `AutoResolveForm`, `DisableIdleTimers`); the fourth `Screen.`
  reference is `Screen.ActiveForm`, which enumerates nothing.
- **`docs/Users Guide.md` listed a `dataset_op` value that does not exist** (2026-09-18,
  **actually fixed 2026-09-21**). Its table gave "insert / append / edit / post / cancel /
  refresh / **navigate**", and the Server unit header used the same shorthand. `AutoCmdDatasetOp`
  accepts `insert`, `append`, `edit`, `post`, `cancel`, `refresh`, `first`, `last`, `next`,
  `prior`; `"op":"navigate"` returns `BadOp`. The 2026-09-18 entry recorded this under **Fixed**
  while leaving both the table row and the unit header untouched — they are corrected now.
- **The coordinate tables in `README.md` and `docs/` quote 150% scaling** (2026-09-18, superseded
  2026-09-21). The original entry called them stale because the scaling changed on 2026-09-14; it
  went **back to 150% on 2026-09-20**, so the figures happen to be correct again. Neither fact is
  worth relying on. The root documents deliberately give the coordinate guidance with no scale
  factor or pixel figures at all, because a recorded coordinate must be re-measured, never
  rescaled — and `tools/click.py` now says so in its own docstring.
- **A pre-standard pair survives at `docs/HELP.md` and `docs/Users Guide.md`** (2026-09-18) —
  wrong location and wrong capitalisation. Left in place; the root `Help.md` says they predate
  the standard, and as of 2026-09-21 `README.md` says so too instead of presenting them as the
  current documentation under a second, anchor-colliding `## Documentation` heading. Whether to
  delete them or reduce them to a redirect is a decision, not a tidy-up.

- **Two `except` blocks no longer hide what went wrong, matching the fix already made in
  `gllAutomationServer`** (2026-09-17) - `src\gllIdeAutomation.Server.pas`. This unit is a sibling of
  GITLAKLib's `gllAutomationServer` and carried the identical code; a Pascal Analyzer sweep found both.
  - **The stopper thread's bare `except` was LOAD BEARING**, so it stays broad. `Stop` waits on
    `while not LFinished do CheckSynchronize( 50 )` and `LFinished := True` sat AFTER the handler, so
    anything escaping would have left that loop spinning for ever. The assignment moves into a
    `finally` and the failure is captured and reported after the join via `OutputDebugString` - not a
    logger, because this is hosted inside `bds.exe` at shutdown, where there is none to reach.
  - **`DeleteDiscovery` narrowed to `EInOutError`** and given the comment it never had; `TFile.Delete`
    raises exactly that on a locked, ACL-denied or already-gone file.
  - Built clean in all four modes, with the DCU timestamps checked in each.

- `TargetedPlatforms` brought into line with the `<Platforms>` block in 1 `.dproj` (2026-09-10)
  The earlier platform sweep removed the non-Windows `<Platform>` entries but left the
  `<TargetedPlatforms>` bitmask untouched, so projects still advertised targets they no
  longer declared — values such as `1048579` and `135171` encode Android/Linux/iOS, and
  several Win32+Win64 projects still read `2` (Win64 only) or `1` (Win32 only).
  Now `3` for Win32+Win64, `2` where only Win64 is declared.
  **Why:** the mask is what the IDE reads for the Project Manager's platform list, so a
  stale one puts dead platforms back in front of the reader.

### Changed

- **Version raised to 1.1.0.0** (2026-09-21) — `gllIdeAutomationVersion.rc`. A minor bump rather
  than a build bump, because the wire contract moved: `SERVER_VERSION` 0.7 → 0.8, `ping` gained a
  field, and two error codes were added. `tools/bump-build.py --show` confirms the numeric defines
  and `VER_STRING` agree, and the built Release BPL reports `1.1.0.0` for both `FileVersion` and
  `ProductVersion`.

- Project platforms normalised to Win32 + Win64 only in 1 `.dproj` file (2026-09-10)
  Non-Windows targets (`Android`, `Android64`, `iOS*`, `OSX*`, `Linux64`) and the
  `Win64x` / `WinARM64EC` variants were removed together with their `Base_<Plat>` and
  `Cfg_N_<Plat>` property groups, `<Deployment>` platform nodes and `<ProjectRoot>`
  entries; a deactivated `Win32` or `Win64` was switched on.
  **Why:** standing suite rule — every gll* project is Delphi 13, Win32 + Win64, nothing
  else, so the four-mode package sweep is always possible.

- Codeberg is retired; every repository URL points at GitHub again (2026-09-05).
  **Why:** hosting consolidated back on GitHub. `origin` is the GitHub URL, the stale
  `codeberg` remote has been removed from the working checkout, and the documentation that
  says where to clone from was updated to match. The Codeberg entry below is superseded;
  its URLs are left as written because rewriting them would falsify the record.

- Repository moved to the `GITLAK-forks` Codeberg organisation: `origin` is now `https://codeberg.org/GITLAK-forks/gllIdeAutomation.git`, and the documentation references were updated to match. **Why:** the `GITLAK` account had reached Codeberg's hard limit of 100 repositories, and an organisation carries its own allowance (2026-09-03) — `CHANGELOG.md`
  **Superseded 2026-09-05:** Codeberg is no longer used; see the entry above.

## [In-Service]

> Libraries and packages are continuously deployed: changes below were live as soon as the package was rebuilt and installed. Tagged version snapshots are listed beneath.
>
> This section is the historical record kept under that model. `## [Unreleased]` above is the
> current one — the note here used to claim there was no `[Unreleased]` backlog while one sat at
> the top of the same file, which was simply wrong. New entries go under `## [Unreleased]`.

### Fixed

- **C++Builder output turned off** (2026-08-26). `DCC_CBuilderOutput` was `All`, so every build emitted `.hpp` / `.bpi` / `.a` / `.obj` files for a compiler that is **never in scope here** (standing rule: "I dont use C++ at all"). Across the estate that was 616 files and 90 MB of output nobody consumes, regenerated on every build; `gllSynEdit` alone accounted for 560. Now `None`. The `DCC_HppOutput` / `DCC_BpiOutput` / `DCC_ObjOutput` properties are left in place deliberately - they only say *where* such files would go, so with generation off they are inert, and removing them would enlarge the diff without changing behaviour. Verified: the affected packages rebuilt clean in every enabled mode, emitted no C++ artefacts, and rebuilt clean again after the existing ones were deleted (so nothing was load-bearing).

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

[Unreleased]: https://github.com/ijbranch/gllIdeAutomation/compare/v1.0.1...main
[1.0.1]: https://github.com/ijbranch/gllIdeAutomation/releases/tag/v1.0.1
[1.0.0]: https://github.com/ijbranch/gllIdeAutomation/releases/tag/v1.0.0

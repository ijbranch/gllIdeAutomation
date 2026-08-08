# gllIdeAutomation

A design-time package that lets you **drive the Delphi IDE from outside it** — list its forms,
read and write published properties, click controls, fire actions, answer modal dialogs, take
screenshots — over a loopback socket, from any language that can open a TCP connection and write
a line of JSON.

It exists because some questions can only be answered by a running IDE. Whether a debug
visualizer is offered on a type, what the evaluator calls that type, how a value renders in Local
Variables: none of that is visible to the compiler, and reading it off screenshots is slow and
error-prone. This makes the IDE inspectable instead.

Delphi **10.3 Rio and later**, Win32 or Win64. MIT licensed.

Fair warning on that range: it is what the source targets — inline variables set the 10.3 floor,
and the `$LIBSUFFIX` selection covers 10.3 through 13 — but **13 Florence is the only version it
has actually been built on**, because it is the only one I have. If you try it on an older IDE I
would be glad to hear how it went, particularly whether the package suffix comes out right.

## What you can do with it

```
$env:GITLAK_IDE_AUTOMATION = '1'
& 'C:\Program Files (x86)\Embarcadero\Studio\37.0\bin64\bds.exe'
```

The IDE now listens on loopback and announces itself in a discovery file. Then, from anything:

```json
{ "token":"…", "id":1, "cmd":"tree" }
{ "id":1, "ok":true, "result":{ "forms":[ {"name":"LocalVarsWindow","class":"TLocalVarsWindow","visible":true}, … ] } }
```

48 IDE forms come back on a stock install, including `LocalVarsWindow`, `WatchWindow`,
`CallStackWindow`, `BPWindow` and `EditWindow_0` — plus the forms of whatever plugins you have,
since it walks `Screen.CustomForms` rather than knowing anything about the IDE.

Commands: `ping`/`info`, `tree`, `get`, `set`, `click`, `action`, `dialogs`, `screenshot`,
`dataset`, `dataset_op`, `field_get`, `field_set`. Forms are addressed by name, `"main"` or
`"active"`; components by their owned name.

## Installing

1. Build `gllIdeAutomation.dproj` for the platform matching your IDE — **Win64 for `bin64\bds.exe`**,
   **Win32 for `bin\bds.exe`**. A design-time package must match the bitness of the IDE loading
   it, and the wrong one silently never loads. Both platforms are configured and both build clean.
2. **Component > Install Packages > Add**, and pick the built BPL. Note the registration is
   per-bitness: the 64-bit IDE reads `Known Packages x64`, the 32-bit IDE reads `Known Packages`.

`tools/Start-IDE.ps1` then launches the IDE correctly and tells you whether the server came up.

## Gating — it does nothing unless you ask

Installing the package does not start anything. The server starts only when the environment
variable `GITLAK_IDE_AUTOMATION` is `1` in the launching environment. An IDE started any other
way is completely unaffected.

Set it permanently (user scope) if you want every IDE to be drivable; leave it unset and use
`Start-IDE.ps1` if you would rather opt in per session.

It is deliberately **not** a command-line switch: `bds.exe` parses its own command line and
treats arguments it does not recognise as files to open.

## Security

Loopback only (`127.0.0.1`), and every command must carry a per-session GUID token that is
written to the discovery file at
`C:\ProgramData\GITLAK\Automation\<pid>.json`. Another local process cannot drive your IDE
without reading that file. There is no remote surface at all.

That said: **this is a development tool.** Anything that can click buttons and set properties in
your IDE deserves the same suspicion you would apply to a debugger. It is off by default for that
reason.

## Reading the debugger panes

`get` cannot read Local Variables or the Watch window: both are `TVirtualStringTree` and their
cell text is not a published property. The panes' popup menu items *are* addressable, so the way
round is to select a row and fire "Copy Value":

```
python tools/read_pane.py 300 1335
'TBaseThing(Name=base)'
```

Selecting the row needs a real mouse click, which `tools/click.py` provides.

### The coordinate trap

On a scaled display there are two coordinate spaces and they do not match. With two 4K monitors
at 150%:

| | Space | Size |
|---|---|---|
| `CopyFromScreen` screenshots | **physical** — it crops, it does not scale | 7680x2160 |
| `SetCursorPos` from a DPI-*unaware* process | **virtualised** | 5120x1440 |

Click a coordinate read off a screenshot without allowing for that and you land two thirds of the
way to the target — silently, with `SendInput` reporting success. `click.py` declares
`PER_MONITOR_AWARE_V2` so both spaces are physical.

It also refuses to click if the cursor will not stay where it was put, so a human moving the
mouse does not receive the click.

**Take coordinates from a fresh screenshot every time.** Row positions shift when a node is
expanded, and a stale coordinate reads a *different row* perfectly happily rather than failing.
Cross-check with `--name`.

## Tools

| Tool | Does |
|---|---|
| `tools/Start-IDE.ps1` | Launches the IDE with the gate set, waits for it to load, reports whether the server came up. Finds the newest installed IDE from the registry; `-Version 22.0` or `-BdsPath` to choose another. `-NoAutomation` for a clean comparison IDE. |
| `tools/click.py` | Clicks at a screen coordinate. Read its docstring before rolling your own. |
| `tools/read_pane.py` | `read_pane.py X Y [--pane locals\|watch] [--name]` — selects the row and prints its value. Speaks the protocol directly; no other tooling needed. |
| `tools/bump-build.py` | `bump-build.py [project.dproj] [--show]` — increments the build number. Needed only for command-line and CI builds; the IDE does it itself. |

## Dependencies

Everything ships with Delphi — clone and build, nothing to acquire:

`rtl`, `vcl`, `vclimg` (screenshots), `dbrtl` (the dataset commands), `IndySystem` + `IndyCore`
(the listener). Notably **not** `designide`: nothing here touches the ToolsAPI, which is also why
it is not tied to any particular IDE version's OTA.

## Why the discovery path says GITLAK

`C:\ProgramData\GITLAK\Automation` is where the server has always written its discovery files, and
existing clients look there. It is a fixed, account-independent location so that a client and the
application agree regardless of either process's `%TEMP%`. The name is historical rather than
meaningful — changing it would break every existing client for no functional gain, so it stays.
It holds one small JSON file per running instance and nothing else.

## Contributing

Issues and patches welcome. Two things worth knowing first:

- `src/gllIdeAutomation.Server.pas` is **vendored** from the library described below, so a fix
  here ideally wants to go upstream too. Nothing keeps the two copies in step automatically.
- Keep it compiling on **10.3 Rio**. The inline variables set that floor already; please don't
  raise it without a good reason. Only 13 Florence is built here, so a report that it does or does
  not compile on an older IDE is genuinely useful — more so than most patches.

## Provenance

The server unit is vendored from GITLAK Software's internal library, where it was written to
drive VCL applications for unattended UI testing. Driving the IDE turned out to need no changes
at all: the IDE is a VCL application, and the unit only ever knew about `Screen.CustomForms` and
published properties.

It is renamed here (`gllIdeAutomation.Server`) rather than copied verbatim, because a Delphi unit
may exist in only one loaded package — a copy under the original name could not load alongside
the library it came from.

## Documentation

- [docs/Users Guide.md](docs/Users%20Guide.md) - the protocol, the command reference, worked
  examples, and the scaling trap that catches everyone who clicks.
- [docs/HELP.md](docs/HELP.md) - short answers for when it is not working.

API documentation is generated from the units' XML doc comments by
[DocInsight](https://devjetsoftware.com/docinsight/); `gllIdeAutomation.diproj` is the project that
builds it, and the output lands in `build/docs` (not tracked). You do not need DocInsight to build
or use the package — only to regenerate those pages.

## Layout

```
gllIdeAutomation.dpk / .dproj   the design-time package
src/gllIdeAutomation.Server     the automation server (vendored)
src/gllIdeAutomation.Starter    ~30 lines: the gate, and the call to Start
tools/                          launcher, clicker, pane reader, build bumper
```

## Keeping it working

- **Rebuild and re-register after a RAD Studio upgrade.** The BPL is version-suffixed and the
  registration is per-version. The suffix is picked by `CompilerVersion` in the `.dpk` — `AUTO` on
  12 Athens and later, an explicit number below that, since `{$LIBSUFFIX AUTO}` is itself a
  12-and-later feature and would otherwise be the thing that broke the build on an older IDE.
- **Check which build is loaded before debugging a misbehaving one.** The BPL carries version
  information, so its Details tab answers the question:

  ```powershell
  (Get-Item "$env:PUBLIC\Documents\Embarcadero\Studio\37.0\Bpl\Win64\gllIdeAutomation370.bpl").VersionInfo.FileVersion
  ```

  The IDE advances the number on each **Build** (not Compile). MSBuild does not: the Delphi
  targets try, then give up with `Failed to increment Build Number. Check the project
  configuration.` and leave it where it was — so a command-line or CI build stamps the same number
  forever unless you run `python tools/bump-build.py` first.
- The starter swallows every exception in `initialization` and `finalization`. An exception
  escaping a design-time package's initialisation is reported to the user as a package load
  failure, for a facility they did not ask for — a port clash must cost the automation server,
  never the IDE.

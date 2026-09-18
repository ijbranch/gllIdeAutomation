# Help — gllIdeAutomation

`gllIdeAutomation` is a **design-time package** (`{$DESIGNONLY}`) that starts the GITLAK
automation server **inside `bds.exe`**, so the running Delphi IDE can be driven and inspected
from outside it over a loopback socket. It exists because some questions can only be answered by
a running IDE — what the evaluator calls a type, whether a visualizer is offered, how a value
renders — and none of that is visible to the compiler.

The source targets **Delphi 10.3 Rio and later** (the `{$LIBSUFFIX}` ladder in
`gllIdeAutomation.dpk` and a `{$MESSAGE FATAL}` below `CompilerVersion 33.0` say so), but this
repository is built and used on **Delphi 13 / RAD Studio 37.0 only**, VCL, **Win32 + Win64**.

This file is the **lookup** document: the Pascal surface, the wire protocol, the error codes, and
the failures with their exact text. For how to get it running and drive it, read
[Users Guide.md](Users%20Guide.md). The history is in [CHANGELOG.md](CHANGELOG.md); the
rationale and the tooling are in [README.md](README.md).

> `docs/HELP.md` and `docs/Users Guide.md` predate the estate documentation standard and are
> still present. This pair at the repository root is the conforming one.

---

## 1. The Pascal surface

Two units, both in `src\`, both listed in the `.dpk` `contains` clause. There is no component to
drop on a form and nothing to register — the package's whole public surface is one static class
plus an `initialization` section.

### `gllIdeAutomation.Server`

| Member | Signature | Purpose |
|---|---|---|
| `TAutomationServer.Start` | `class procedure Start( const AAppName: string )` | Starts the singleton loopback server, advertising `AAppName`. Idempotent. |
| `TAutomationServer.Stop` | `class procedure Stop` | Stops and frees the server, removing the discovery file. Idempotent. |
| `TAutomationServer.IsRunning` | `class function IsRunning: Boolean` | True while the server is running. |
| `TAutomationServer.Port` | `class function Port: Word` | The bound loopback port; `0` when not running. |

Implementation-only constants worth knowing, because they define observable behaviour:

| Constant | Value | Meaning |
|---|---|---|
| `AUTOMATION_PORT_BASE` | `8730` | First loopback port tried. |
| `AUTOMATION_PORT_SPAN` | `200` | Consecutive ports probed before the bind is abandoned. |
| `SERVER_VERSION` | `'0.7'` | Reported as `server` by `ping`/`info`. |
| `DISCOVERY_DIR` | `C:\ProgramData\GITLAK\Automation` | Where the per-PID discovery file is written. |

### `gllIdeAutomation.Starter`

No interface section at all — it is `interface` / `implementation` with an empty interface. Its
entire job is the gate:

| Constant | Value | Meaning |
|---|---|---|
| `ENV_GATE` | `GITLAK_IDE_AUTOMATION` | Must be `1` (after `Trim`) or nothing starts. |
| `APP_NAME` | `DelphiIDE` | The name the IDE is advertised under — this is what `app_list` shows. |

Both `initialization` and `finalization` are wrapped in a bare `try..except` that swallows
everything **deliberately**: an exception escaping a design-time package's initialisation is
reported to the user as a package load failure, for a facility they did not ask for. A port clash
must cost the automation server, never the IDE.

---

## 2. The wire protocol

Loopback TCP (`127.0.0.1`), one JSON object per line in, one line out. Every request must carry
the `token` from that instance's discovery file, or the connection is answered with
`Unauthorised` before the command is even looked at.

### Request envelope

| Field | Required | Meaning |
|---|---|---|
| `token` | yes | The per-session GUID from the discovery file. Checked first. |
| `id` | no | Echoed back on the response. Defaults to `0`. |
| `cmd` | yes | One of the commands below. |

### Addressing

| Key | Accepts |
|---|---|
| `form` | a form's `Name`, `main`, or `active`. Omitted or empty resolves to the main form. |
| `name` | a component **owned** by that form. Ownership, not parenting. Omit to address the form itself. |

### Commands

Read out of `TServerImpl.ExecuteCommand` and the `AutoCmd*` functions.

| `cmd` | Request fields | Result |
|---|---|---|
| `ping` / `info` | — | `{ app, pid, version, exe, mainForm, server }` |
| `tree` | `form?` | No `form`: `{ forms:[ { name, class, visible } … ] }` over `Screen.Forms`. With `form`: `{ form, class, components:[ … ] }` |
| `get` | `form?`, `name?`, `prop` | `{ name, prop, value }` |
| `set` | `form?`, `name?`, `prop`, `value` | `{ name, prop, value }` — the value **read back** after the write |
| `click` | `form?`, `name`, `mode?` | `{ clicked, mode }`, plus `posted:true` in message mode |
| `action` | `form?`, `name` | `{ executed, fromComponent }` |
| `dialogs` | `button?` | No `button`: `{ windows:[ { hwnd, class, caption, owned, enabled, buttons } … ] }`. With `button`: `{ clicked, dialog }` |
| `screenshot` | `area?` | `{ path, width, height, area }` |
| `dataset` | `form?`, `name`, `fields?` | `{ dataset, active, recordCount, recNo, bof, eof }`, plus `fields` when `fields:true` |
| `dataset_op` | `form?`, `name`, `op` | `{ dataset, op, state, recNo }` |
| `field_get` | `form?`, `name`, `field` | `{ dataset, field, type, isNull, value }` |
| `field_set` | `form?`, `name`, `field`, `value` | `{ dataset, field, state, isNull, value }` |

There is no `wait` command. Polling is a client concern; a blocking wait would hold the
connection and the VCL thread it marshals onto.

### Command arguments with a fixed vocabulary

| Field | Command | Accepted values |
|---|---|---|
| `mode` | `click` | `direct` (default — calls `OnClick`) or `message` (posts `BM_CLICK` and replies at once). Anything else → `BadMode`. |
| `op` | `dataset_op` | `insert`, `append`, `edit`, `post`, `cancel`, `refresh`, `first`, `last`, `next`, `prior`. Lower-cased and trimmed first; anything else → `BadOp`. |
| `area` | `screenshot` | `virtual` (the whole virtual screen), `window` (the app's active window rect), anything else → the monitor the active window is on. The result's `area` field reports which of `virtual` / `window` / `monitor` was used. |

### Which thread a command runs on

This is not cosmetic — it is why some commands work while a modal dialog is blocking and others
do not.

| Runs on the worker thread | Runs marshalled to the main VCL thread |
|---|---|
| `dialogs`, `screenshot` | everything else |

`dialogs` enumerates top-level windows with the Win32 API and clicks with
`SendMessageTimeout( …, BM_CLICK, …, SMTO_ABORTIFHUNG, 5000, … )`, so it still answers a dialog
whose modal loop has blocked `Synchronize`. `screenshot` sets
`SetThreadDpiAwarenessContext( THandle( -4 ) )` — per-monitor-aware V2 — on the capture thread,
so it captures in physical pixels even though the IDE's UI thread is DPI-unaware.

### Properties returned by `tree`

`tree` does **not** dump every published property. `CompToJSON` emits a fixed ten, and only those
the component actually publishes:

`Caption`, `Text`, `Visible`, `Enabled`, `Checked`, `ItemIndex`, `Left`, `Top`, `Width`, `Height`

Anything else needs an explicit `get`.

### The discovery file

One per running instance, at `C:\ProgramData\GITLAK\Automation\<pid>.json`, **written with a
UTF-8 BOM** — read it with `encoding="utf-8-sig"` or `json.load` throws.

| Field | Source |
|---|---|
| `app` | the `AAppName` passed to `Start` — `DelphiIDE` for this package |
| `pid` | `GetCurrentProcessId` |
| `port` | the bound loopback port |
| `token` | `TGuid.NewGuid.ToString`, regenerated every session |
| `started` | `DateToISO8601( Now, False )` — local time, no false `Z` |

It is deleted on clean shutdown. A file left behind means the IDE died; the name is the PID, so
check the process is alive before trusting it.

---

## 3. Error codes

Every failure returns `{ id, ok:false, error:{ code, message } }` with a stable `code`. The full
set, from the `EAutoError.CreateCode` sites and the two pre-dispatch failures:

| Code | Raised when |
|---|---|
| `BadRequest` | the line did not parse as a JSON object |
| `Unauthorised` | `token` is missing or does not match this session's |
| `UnknownCmd` | `cmd` is not one of the commands above |
| `NoForm` | no form of that name; or `main` with no main form yet; or `active` with no active form |
| `NoComp` | the named component is not **owned** by the resolved form |
| `NoProp` | the property is not published on that component (`get` and `set`) |
| `NotButton` | `mode=message` on something that is not a button-class control |
| `NotClickable` | the button is not both visible and enabled |
| `BadMode` | `click` `mode` is neither `direct` nor `message` |
| `NoOnClick` | the component has no `OnClick` property at all |
| `NoHandler` | it has `OnClick` but nothing is assigned to it |
| `NoAction` | the target is neither a `TBasicAction` nor a control with an assigned `Action` |
| `ActionDisabled` | the resolved action is disabled |
| `NoButton` | no open dialog has a visible, enabled button matching the requested caption |
| `NotDataSet` | the component is neither a `TDataSet` nor a `TDataSource` |
| `DataSetClosed` | the dataset is not open |
| `NoField` | the dataset has no field of that name |
| `ReadOnlyField` | `field_set` on a read-only field |
| `BadOp` | `dataset_op` `op` is not in the vocabulary above |
| `CaptureFailed` | the GDI screen capture failed |
| `Internal` | any other exception escaping the command |

---

## 4. Scope of this fork

**There is no upstream.** `git remote -v` shows `origin` only
(`https://github.com/ijbranch/gllIdeAutomation.git`). This is a GITLAK original, not a fork of a
third-party project, so there is nothing to merge from and no divergence to justify.

What it **is** is a **vendored copy**, and that is the divergence that matters:

- `src\gllIdeAutomation.Server.pas` is vendored from GITLAKLib's `gllAutomationServer`. The unit
  header states the body is unchanged — only the header, the unit name and one exception message
  differ — so this package depends on the RTL, the VCL and Indy alone, and **not** on GITLAKLib.
- **The rename is deliberate and must not be undone.** A Delphi unit may exist in only one loaded
  package, so a copy still called `gllAutomationServer` could not load into an IDE that already
  has GITLAKLib installed — which is exactly the machine this was written on.
- **Nothing keeps the two copies in step automatically.** A fix here should be carried back to
  GITLAKLib and vice versa. The 2026-09-17 `except`-block fix in `CHANGELOG.md` is an instance of
  a Pascal Analyzer sweep finding the same defect in both.
- The package deliberately does **not** require `designide`. Nothing here touches the ToolsAPI,
  which is why it is not tied to any particular IDE version's OTA.

The version is defined in exactly one place, `gllIdeAutomationVersion.rc`, and the `.dproj` sets
`VerInfo_IncludeVerInfo=false` so the IDE's own per-configuration version fields cannot compete
with it. Nothing advances the number automatically; `tools/bump-build.py` does.

---

## 5. Building

`gllIdeAutomation.dproj` is a package project and follows the estate package rules.

- **Four modes.** Win32 + Win64 × Debug + Release. `<Platforms>` declares exactly `Win32=True`
  and `Win64=True`, and `TargetedPlatforms` is `3` to match. The package is only finished when
  all four are built.
- **Which platform you actually need to install** is the bitness of the IDE: `bin64\bds.exe`
  loads the **Win64** BPL, `bin\bds.exe` loads the **Win32** one. The wrong one silently never
  loads.
- **Output.** The `.dproj` carries the estate standard verbatim:

  ```xml
  <DCC_BplOutput Condition="'$(Config)'=='Release'">$(BDSCOMMONDIR)\Bpl\$(Platform)</DCC_BplOutput>
  <DCC_BplOutput Condition="'$(Config)'!='Release'">$(BDSCOMMONDIR)\Bpl\$(Platform)\$(Config)</DCC_BplOutput>
  <DCC_DcpOutput Condition="'$(Config)'=='Release'">$(BDSCOMMONDIR)\Dcp\$(Platform)</DCC_DcpOutput>
  <DCC_DcpOutput Condition="'$(Config)'!='Release'">$(BDSCOMMONDIR)\Dcp\$(Platform)\$(Config)</DCC_DcpOutput>
  ```

  Release stays in the shared platform folder because that folder is on `PATH` and is where
  dependent packages resolve their `requires`; only Debug is diverted, which is enough to stop a
  Debug build replacing the installed Release package.
- **DCUs are project-local and per-platform, per-config:** `DCC_DcuOutput` is
  `.\dcu\$(Platform)\$(Config)`. Do not flatten it — one folder shared by two architectures gives
  every consumer `F2048 Bad unit format`.
- `DCC_CBuilderOutput` is `None`. C++Builder is never in scope.
- The BPL name carries a version suffix chosen in the `.dpk` by `CompilerVersion`: `AUTO` on 12
  Athens and later, an explicit `280` / `270` / `260` below that. `{$LIBSUFFIX AUTO}` is itself a
  12-and-later feature, so the ladder is what keeps the `.dpk` compiling on an older IDE.

---

## 6. Troubleshooting

### Building fails with **two** `F2039 Could not create output file` errors

```
F2039 Could not create output file '...\Bpl\Win64\gllIdeAutomation370.bpl'
F2039 Could not create output file '...\Dcp\Win64\gllIdeAutomation.dcp'
```

An IDE with the package installed holds **both** outputs open. The count is the diagnostic: two
errors, no compilation errors, and the compiler reports its unit count normally. This is a file
lock, not a code fault, and it applies to MSBuild and `dcc64` exactly as it does to a build from
inside the IDE.

Untick the package in **Component > Install Packages**, build, re-tick; or build with `bds.exe`
closed.

**Never pass `clean` while the IDE holds it.** `CleanOutputs` deletes the `.dcp` *first* and only
then discovers it cannot delete the loaded `.bpl`, so a failed clean build leaves the DCP gone and
every consumer failing `E2202 Required package '<x>' not found` — and it cannot be regenerated
until the IDE closes, because the link step that writes the DCP is the one being blocked.

### The package is installed but the IDE never appears in the discovery directory

Work down this list; in practice it is always one of them.

1. **The gate was not set in the launching environment.** A process gets its environment at
   creation, so setting `GITLAK_IDE_AUTOMATION` *after* the IDE started does nothing. The gate is
   `Trim(value) = '1'` — not "set", not "true".
2. **Wrong bitness.** Win64 BPL for `bin64\bds.exe`, Win32 for `bin\bds.exe`.
3. **The package is registered under the wrong IDE key.** Design packages register per IDE
   bitness: `HKCU\…\BDS\37.0\Known Packages` is the 32-bit IDE's list, `Known Packages x64` the
   64-bit one. Install from `bin64\bds.exe`.
4. **The tick is cleared** in Component > Install Packages — the IDE loaded it, failed, and
   disabled it.
5. **It is not the process you think.** The discovery filename is the PID; check it against
   `Get-Process bds`.

### `Error Reading Form: Class TXxx not found`

Not this package's own failure mode, but the symptom of the mis-registration in point 3 above for
any design-time package. **Never click Ignore** — it drops the component and its property values
from the form, and saving writes the loss into the `.dfm`.

### It worked yesterday

- **A RAD Studio update.** The BPL is version-suffixed and registration is per-version. Rebuild
  and re-register.
- **The IDE is loading an older build.** Check rather than assume:

  ```powershell
  (Get-Item "$env:PUBLIC\Documents\Embarcadero\Studio\37.0\Bpl\Win64\gllIdeAutomation370.bpl").VersionInfo.FileVersion
  ```

  If that number has not moved, the build did not reach the BPL the IDE loads. Nothing advances
  it on its own, so two builds with no `bump-build.py` between them legitimately report the same
  version — a matching number is not by itself proof of a stale build.
- **The IDE was launched from somewhere that does not carry the variable** — a shortcut, a file
  association, another tool.

### A command returns `Unauthorised`

The token is per-session: it is a fresh `TGuid.NewGuid` every time the server starts, so a cached
one goes stale the moment the IDE restarts. Re-read the discovery file.

### The port is not 8730

Expected. The constructor scans upward from `AUTOMATION_PORT_BASE` (8730) for up to
`AUTOMATION_PORT_SPAN` (200) ports, so two gated IDEs get different ones. Always read `port` from
the discovery file. If all 200 fail, `Start` raises
`gllIdeAutomation: no free loopback port in range` — and the starter swallows it, so the symptom
is simply no discovery file.

### `NoForm` / `NoComp` / `NoProp`

- `NoForm` — send `tree` with no `form` to list what is actually open. Many IDE windows exist but
  are not visible until first used.
- `NoComp` — the component is not *owned* by that form. Send `tree` with the form name to see the
  owned components.
- `NoProp` — the property is not published. This is the usual wall; see the next entry.

### `get` cannot read the debugger panes — and this is structural

**Local Variables, Watch and the Structure pane are `TVirtualStringTree`. Their cell text is not
a published property, and neither is the selection.** No amount of `get` will reach it, because
the server reads published properties through RTTI and there is nothing published to read.

The way round is that the panes' popup menu items *are* addressable components: select a row with
a real mouse click, then fire Copy Value and read the clipboard. `tools/read_pane.py` does exactly
that. The two panes do not share naming — Locals has `lvCopyValue` / `lvCopyName`, Watch has
`CopyWatchValue` / `CopyWatchName` — so confirm with `tree` rather than assuming symmetry.

### Copy Value produces nothing

No row is selected. Firing the popup item acts on the current selection; an empty selection gives
an empty clipboard. Click the row first. `read_pane.py` primes the clipboard with a sentinel so
"nothing was copied" and "the value is genuinely empty" do not look identical.

### The `app_*` tools cannot see an add-in's frame

**They walk form ownership.** `tree` enumerates `Screen.Forms`, and with a `form` it enumerates
that form's *owned* components one level deep. An add-in that parents a frame into an IDE window
without that window owning it is not reachable this way, and no `form` name will find it.

To establish that an add-in BPL is loaded at all, **look at the process module list** — enumerate
the modules of the `bds.exe` process and look for the BPL by name. That is a fact about the
process, not about the VCL ownership graph, so it answers the question the automation server
cannot.

### The IDE hangs while a command runs

A command whose handler opens a modal dialog blocks until the dialog closes, because the reply
waits for the handler to return. Use `"mode":"message"` on `click` for button-class controls — it
posts `BM_CLICK` and replies immediately — then answer the dialog with `dialogs`.

### A click lands in the wrong place

Only relevant to `tools/click.py` and anything else synthesising real mouse input; the protocol
itself is coordinate-free. On a scaled display, screenshot pixels and cursor coordinates are
**different spaces**, and `SendInput` reports success either way, so a mis-scaled click fails
silently rather than erroring. Take coordinates from a fresh screenshot every time — row
positions shift when a node is expanded, and a stale coordinate reads a *different row* perfectly
happily.

`click.py` declares `PER_MONITOR_AWARE_V2` so both spaces are physical, and it refuses to click
if the cursor will not stay where it was put, so a human on the mouse does not receive the click.

---

## 7. Dependencies

Everything ships with Delphi. Clone and build; there is nothing to acquire.

| `requires` | Needed for |
|---|---|
| `rtl` | — |
| `vcl` | `Screen.CustomForms`, published-property access, `TAction` |
| `vclimg` | `Vcl.Imaging.pngimage` — the `screenshot` command |
| `dbrtl` | `Data.DB` — the `dataset` / `dataset_op` / `field_*` commands |
| `IndySystem`, `IndyCore` | `TIdTCPServer` — the loopback listener |

Notably **not** `designide`. Nothing here touches the ToolsAPI.

The dataset commands are inherited from the server's origin driving database applications. They
are of little practical use against the IDE itself, but they cost nothing and they are why
`dbrtl` is required.

---

## 8. Security

Loopback only (`127.0.0.1`), and every command must carry the per-session GUID token from
`C:\ProgramData\GITLAK\Automation\<pid>.json`. Another local process cannot drive the IDE without
reading that file. There is no remote surface.

That said, this is a development tool: anything that can click buttons and set properties in an
IDE deserves the suspicion you would apply to a debugger. It is off by default for that reason,
and the package is inert unless the gate is set — so leaving it installed costs nothing, and
whether to set the variable permanently is the decision to take deliberately.

The server unit's own header states it plainly: **it must not be started in a shipped
application.** That is a conditional-compilation and opt-in discipline on the consumer's side,
not something the package can enforce.

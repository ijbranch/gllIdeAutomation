# Users Guide — gllIdeAutomation

This is the **narrative** document: how to get the package into an IDE, how to talk to it, and
what to do with it once it answers. For a member, a command field, an error code or a failure by
symptom, go to [Help.md](Help.md) instead.

The premise is one sentence: **the Delphi IDE is a VCL application.** Its windows are `TForm`
descendants owning named components that publish properties and are wired to `TAction`s — the
same model your own applications use. This package starts a small server inside `bds.exe` that
exposes that model over a loopback socket, so instead of synthesising keystrokes and reading
pixels you ask the IDE what it has and tell it what to do.

It knows nothing about the IDE specifically: it walks `Screen.Forms`, so plug-in windows appear
alongside the IDE's own without the server having heard of them.

---

## 1. Build the package

Open `gllIdeAutomation.dproj` on Delphi 13. (On an older IDE, open `gllIdeAutomation.dpk`
instead and let that IDE write its own `.dproj` beside it — the `.dpk` is the real project and is
version-agnostic; the `.dproj` here is the MSBuild wrapper Delphi 13 generated. Do not commit the
one yours produces.)

Build **all four modes** — Win32 + Win64 × Debug + Release. It is a package, and a package is only
finished when all four are built; the `.dproj` declares both platforms and both configurations.

The mode that matters for *installing* is the platform that matches the IDE:

| You launch | You install |
|---|---|
| `…\Studio\37.0\bin64\bds.exe` | the **Win64** BPL |
| `…\Studio\37.0\bin\bds.exe` | the **Win32** BPL |

A design-time package must match the bitness of the IDE loading it, and the wrong one silently
never loads.

If you want two builds to be distinguishable afterwards, bump the version **before** building:

```powershell
python tools\bump-build.py
```

Nothing advances that number automatically — it is defined once, in
`gllIdeAutomationVersion.rc`, and the `.dproj` sets `VerInfo_IncludeVerInfo=false` so the IDE's
own per-configuration version fields cannot compete with it.

> If the build stops with **two** `F2039 Could not create output file` errors and no compilation
> errors, an IDE has the package installed and is holding the `.bpl` and the `.dcp` open. See
> [Help.md](Help.md#building-fails-with-two-f2039-could-not-create-output-file-errors) — and do
> not pass `clean` in that state.

---

## 2. Install it

**Component > Install Packages > Add**, and pick the built BPL.

Do this from **`bin64\bds.exe`**. Registration is per IDE bitness: the 64-bit IDE reads
`Known Packages x64`, the 32-bit IDE reads `Known Packages`. Installing a Win64 BPL from the
32-bit IDE writes it into a key where it can never load, and the symptom is not a package error
but `Error Reading Form: Class TXxx not found` later, in an unrelated form.

Installing starts nothing. The package is inert until you set the gate.

---

## 3. Start an IDE with automation enabled

The server runs only when `GITLAK_IDE_AUTOMATION` is `1` in the environment the IDE was launched
from. Per session:

```powershell
$env:GITLAK_IDE_AUTOMATION = '1'
Start-Process 'C:\Program Files (x86)\Embarcadero\Studio\37.0\bin64\bds.exe'
```

Or permanently, so every IDE is drivable:

```powershell
[Environment]::SetEnvironmentVariable( 'GITLAK_IDE_AUTOMATION', '1', 'User' )
```

A process gets its environment at creation, so **setting the variable after the IDE has started
has no effect.**

`tools\Start-IDE.ps1` does the launch and tells you whether the server came up. It finds the
newest installed IDE from the registry; `-Version` or `-BdsPath` chooses another, and
`-NoAutomation` starts a clean comparison IDE.

It is deliberately **not** a command-line switch: `bds.exe` parses its own command line and
treats arguments it does not recognise as files to open.

The IDE now announces itself as **`DelphiIDE`** — that is the `APP_NAME` constant in
`gllIdeAutomation.Starter`, and it is what `app_list` reports.

---

## 4. Find the instance

Each running instance writes one file to `C:\ProgramData\GITLAK\Automation\<pid>.json`:

```json
{ "app":"DelphiIDE", "pid":7948, "port":8730, "token":"{7FAF15B3-…}", "started":"2026-08-08T08:53:09+10:00" }
```

Three things to know about it:

- **Read the port from the file.** The server scans upward from 8730 for a free port, so two
  gated IDEs get different ones. Assuming 8730 works until the day it does not.
- **The token is per session.** It is a fresh GUID each time the server starts, so a cached one
  goes stale when the IDE restarts.
- **It is written with a UTF-8 BOM.** Read it with `encoding="utf-8-sig"` in Python, or
  `json.load` throws.

The file is deleted on clean shutdown. One left behind means the IDE died without cleaning up —
the name is the PID, so check the process is alive before trusting it. **This matters more than it
sounds**: the obvious way to find the IDE is to take the first file whose `app` is `DelphiIDE`,
which is exactly what `tools\read_pane.py` does, so a single corpse makes a perfectly healthy IDE
look unreachable. The server sweeps the directory on startup and deletes any `<pid>.json` whose
process has gone, which clears the common case, but a consumer should still check.

A fourth thing, if you are looking at the folder's permissions: it is created with a **protected**
DACL naming only `SYSTEM`, `BUILTIN\Administrators` and the account the IDE runs as. That is
because the file holds the token, and `C:\ProgramData` otherwise grants every local user read. An
*existing* folder is left as it is — see [Help.md §8](Help.md#8-security) for why, and for the
one-line check.

---

## 5. The smallest thing that works

One request line, one response line. From PowerShell, with nothing installed but PowerShell:

```powershell
$d = Get-Content (Get-ChildItem 'C:\ProgramData\GITLAK\Automation\*.json')[0].FullName -Raw |
     ConvertFrom-Json
$c = New-Object Net.Sockets.TcpClient( '127.0.0.1', $d.port )
$s = $c.GetStream()
$w = New-Object IO.StreamWriter( $s )
$r = New-Object IO.StreamReader( $s )
$w.WriteLine( ( @{ token = $d.token; id = 1; cmd = 'ping' } | ConvertTo-Json -Compress ) )
$w.Flush()
$r.ReadLine() | ConvertFrom-Json
```

`ping` answers `{ app, pid, version, package, exe, mainForm, server }`, where `server` is the
protocol version (`0.8`). The two version fields are **not** the same thing and the distinction is
the point: `version` is the **host's** — inside the IDE that is `bds.exe`'s, something like
`37.0.60952.8797` — while `package` is this package's own BPL version, which is how you tell which
build of `gllIdeAutomation` the IDE has actually loaded. If that returns, everything from here is
detail.

From Python, the whole client is ten lines — `tools\read_pane.py` carries this one:

```python
def command( port, token, **fields ):
    payload = json.dumps( { "token": token, "id": 1, **fields } ) + "\n"
    with socket.create_connection( ( "127.0.0.1", port ), timeout = 10 ) as s:
        s.sendall( payload.encode( "utf-8" ) )
        buf = b""
        while not buf.endswith( b"\n" ):
            buf += s.recv( 4096 )
    return json.loads( buf.decode( "utf-8" ) )
```

---

## 6. Find out what is open

```json
{ "token":"…", "id":1, "cmd":"tree" }
```

comes back as a shallow list of every form in `Screen.Forms`, each with `name`, `class` and
`visible`. On a stock IDE that includes `LocalVarsWindow`, `WatchWindow`, `CallStackWindow`,
`BPWindow` and `EditWindow_0`, plus the forms of whatever plug-ins are installed. Many of them
exist but are not visible until first used, so an invisible form in the list is normal.

Name a form and you get its owned components one level deep:

```json
{ "token":"…", "id":2, "cmd":"tree", "form":"LocalVarsWindow" }
```

Each component comes back as `{ name, class, props }`, where `props` holds only the ten
properties `tree` bothers with — `Caption`, `Text`, `Visible`, `Enabled`, `Checked`, `ItemIndex`,
`Left`, `Top`, `Width`, `Height` — and only those the component actually publishes. Anything else
needs an explicit `get`.

**Ownership, not parenting.** `tree` lists what the form *owns*. A control parented into a form by
something else is not in the list and cannot be addressed by name.

---

## 7. Read and write properties

```json
{ "cmd":"get", "form":"LocalVarsWindow", "name":"cbContext", "prop":"Text" }
{ "id":1, "ok":true, "result":{ "name":"cbContext", "prop":"Text", "value":"TestVisualizers" } }
```

`set` takes a `value` and **reads the property back** after writing, so the response tells you
what the property actually holds rather than what you asked for — which is how you find out that
a coerced or rejected write did not take:

```json
{ "cmd":"set", "form":"MyForm", "name":"edName", "prop":"Text", "value":"Smith" }
{ "id":1, "ok":true, "result":{ "name":"edName", "prop":"Text", "value":"Smith", "previous":"Jones", "changed":true } }
```

`previous` is what the property held before the write and `changed` compares the two, so a write
that was silently ignored is visible without a second `get`. **Both fields are omitted together**
when the property has no readable getter, or when its getter raised — so test for `changed` before
trusting it rather than treating a missing one as `false`.

`form` may be a form's `Name`, `"main"` or `"active"`; omit it and you get the main form. Omit
`name` and you address the form itself, which is how you read a form's `Caption` or `Visible`.

Only **published** properties are reachable. `NoProp` means the property is not published, not
that you spelled it wrong — and the failure carries `error.data.properties`, the ones the object
*does* publish with their live values, so a near-miss corrects itself without another round-trip.

---

## 8. Make something happen

Two commands, and the difference between them is what you are aiming at.

**`click`** fires the component's `OnClick`:

```json
{ "cmd":"click", "form":"LocalVarsWindow", "name":"lvCopyValue" }
```

If the control has no `OnClick` you get `NoOnClick`; if it has one but nothing is assigned,
`NoHandler`. Most trees, grids and panels fall into the first case — the interaction you are
trying to reproduce is mouse-position dependent, and no amount of `click` will reach it.

**`action`** executes a `TAction` — either the named component itself, or the action assigned to a
named control:

```json
{ "cmd":"action", "form":"main", "name":"actBuildProject" }
```

This is how you invoke menu and toolbar commands, because that is how they are wired. A disabled
action returns `ActionDisabled` rather than silently doing nothing.

---

## 9. Handle a modal dialog

This is the one sequencing trap worth learning before you hit it.

`click` in its default `direct` mode calls `OnClick` **and waits for it to return**. If the
handler opens a modal dialog, the handler does not return until the dialog is answered — so your
request blocks, and it looks like the IDE has hung.

Use `mode=message` instead. It posts `BM_CLICK` and replies immediately:

```json
{ "cmd":"click", "form":"main", "name":"btnSave", "mode":"message" }
{ "id":1, "ok":true, "result":{ "clicked":"btnSave", "mode":"message", "posted":true, "clicksDispatched":1 } }
```

Then answer the dialog:

```json
{ "cmd":"dialogs" }
{ "cmd":"dialogs", "button":"Yes" }
```

`dialogs` with no `button` lists the open top-level windows with their visible, enabled buttons;
with a `button` it clicks the first whose caption matches, ignoring the `&` accelerator marker
and surrounding whitespace, and returns `{ clicked, dialog, dismissed }`.

**Read `dismissed`, not just `clicked`.** `clicked` says a message was sent; `dismissed` says the
window actually went away. The two differ for a custom-drawn button — a styled control keeps a
window class containing `button`, so it is found, but its window procedure may not implement
`BM_CLICK`, and the send then succeeds while nothing happens. The server falls back to the mouse
messages every `TControl` handles and then waits briefly to see the window close, which is what
`dismissed` reports.

**Why this works while the IDE is blocked:** `dialogs` runs on the worker thread, not the VCL
thread. It enumerates windows with the Win32 API and clicks with `SendMessageTimeout( …,
SMTO_ABORTIFHUNG, 5000, … )`, so a modal loop that has blocked `Synchronize` does not stop it.
`mode=message` requires a button-class control — anything else returns `NotButton`, and a button
that is not both visible and enabled returns `NotClickable`.

`click` also takes a `count` (1 to 1000; outside that, `BadCount`) and reports `clicksDispatched`.
That is not the same number when a handler raises part-way through: in `direct` mode the raise is
caught and reported as `stoppedReason` / `stoppedMessage` rather than escaping, so you learn both
that it failed and how far it got. Note the consequence — a `direct` click never reaches
`Application.HandleException`, so use `mode=message` when the point is to exercise a global error
path.

---

## 10. Take a screenshot

```json
{ "cmd":"screenshot" }
{ "id":1, "ok":true, "result":{ "path":"C:\\Users\\…\\Desktop\\DelphiIDE-1234567.png", "width":3840, "height":2160, "area":"monitor" } }
```

The PNG is written to the Desktop and the path is returned — the *real* Desktop, resolved through
the known-folder API, so it still lands where you will find it when the Desktop is redirected to
OneDrive. Nothing cleans these up; they accumulate until you delete them. `area` chooses what is
captured:

| `area` | Captures |
|---|---|
| omitted or anything else | the monitor the app's active window is on (`area` comes back as `monitor`) |
| `"window"` | the active window's rect |
| `"virtual"` | the whole virtual screen |

Like `dialogs`, this runs off the VCL thread, so it captures a blocking dialog. It also sets
per-monitor-aware V2 on the capture thread, so the image is in **physical** pixels at the
monitor's native resolution even though the IDE is DPI-unaware.

That last point is the one to remember: **screenshot pixels are not the same coordinate space as
cursor positions.** See section 12.

---

## 11. Read the debugger panes

`get` cannot read Local Variables or the Watch window, and this is structural rather than a gap
to be filled: both are `TVirtualStringTree`, and neither their cell text nor their selection is a
published property. The server reads published properties through RTTI, so there is nothing for
it to read.

What *is* addressable is each pane's popup menu items. So the route is: select a row with a real
mouse click, fire Copy Value, read the clipboard.

```
python tools\read_pane.py 300 1335
'TBaseThing(Name=base)'

python tools\read_pane.py 300 1335 --name
Base
```

`--pane watch` reads the Watch window instead. The two panes **do not share naming** — Locals has
`lvCopyValue` / `lvCopyName`, Watch has `CopyWatchValue` / `CopyWatchName` — so confirm with
`tree` rather than assuming symmetry.

If Copy Value produces nothing, no row is selected: firing the popup item acts on the current
selection, and an empty selection gives an empty clipboard. `read_pane.py` primes the clipboard
with a sentinel so that "nothing was copied" and "the value is genuinely empty" do not look
identical.

**Take coordinates from a fresh screenshot every time.** Row positions shift whenever a node is
expanded or the pane is resized, and a stale coordinate reads a *different row* perfectly happily
— it does not fail, it answers the wrong question. Reading `--name` as well as the value costs one
call and catches it.

---

## 12. Clicking, and the coordinate trap

Everything above is coordinate-free. This section is only for the cases — selecting a tree row,
essentially — where a genuine mouse click is unavoidable.

**On a scaled display there are two coordinate spaces and they do not match.**

| | Space |
|---|---|
| `CopyFromScreen` screenshots | **physical** — it crops, it does not scale |
| `SetCursorPos` from a DPI-**unaware** process | **virtualised** by the scale factor |

They differ by exactly the scaling factor. Feed a coordinate read off a screenshot straight into
`SetCursorPos` from an unaware process and the click lands short of the target — **silently**.
`SendInput` returns success and nothing happens.

`tools\click.py` declares `PER_MONITOR_AWARE_V2` before touching the cursor, so both spaces are
physical. Two further points, both learned by getting them wrong:

- **Button events with no coordinates apply wherever the cursor is at that instant.** If a human
  moves the mouse between your move and your click, the click lands in their window. `click.py`
  verifies the cursor stayed put immediately before each press and aborts otherwise.
- Injecting input from PowerShell via `Add-Type` and P/Invoke may be blocked by AMSI as suspicious
  script content. Python `ctypes` is not scanned the same way.

---

## 13. The dataset commands

`dataset`, `dataset_op`, `field_get` and `field_set` are inherited from the server's origin —
driving database applications under test — and they are why `dbrtl` is a `requires`. Against the
IDE itself they have little use, but they cost nothing and they work against any VCL application
this server is hosted in.

```json
{ "cmd":"dataset",    "name":"qryOrders", "fields":true }
{ "cmd":"dataset_op", "name":"qryOrders", "op":"edit" }
{ "cmd":"field_set",  "name":"qryOrders", "field":"Qty", "value":5 }
{ "cmd":"field_get",  "name":"qryOrders", "field":"Qty" }
```

`op` accepts exactly `insert`, `append`, `edit`, `post`, `cancel`, `refresh`, `first`, `last`,
`next`, `prior` — anything else is `BadOp`. `field_set` puts a browsing dataset into edit mode
first, and reaches values that data-aware controls hide behind unpublished properties.

`name` may be a `TDataSet` or a `TDataSource`; anything else gives `NotDataSet`, and a closed
dataset gives `DataSetClosed` — from `dataset_op`, `field_get` and `field_set`, but **not** from
`dataset`, which reports `{ dataset, active:false }` and stops there. Read `active` before you read
`recordCount`, `recNo`, `bof` or `eof`, because a closed dataset simply does not carry them.

---

## 14. Practical notes

**There is no `wait` command, and there will not be one.** Waiting is a client concern: poll `get`
on the property you care about. A blocking wait on the server would tie up the connection and,
worse, hold the VCL thread it marshals onto.

**A request always gets a reply.** A malformed envelope — a field of the wrong JSON type, an
unknown command, a bad token — comes back as an error object carrying your `id`, never as a
closed connection. The single exception is a request line over 1 MB, which is answered with
`RequestTooLong` and *then* disconnected, because the rest of that line would otherwise be read as
though it were your next request. So if you ever see a connection close without a reply, that is a
genuine fault worth reporting rather than something you did.

**The IDE is not modified behind your back.** This package reads the IDE's component model and
does what you ask; it does not adjust the IDE to suit itself. In particular it does not disable
IDE or plug-in timers, which the upstream version of this server does when driving an application
that might log itself out mid-test.

**Know which thread a command runs on.** `dialogs` and `screenshot` run on the worker thread;
everything else is marshalled to the main VCL thread. That is precisely why those two still work
while a modal loop is blocking and the others do not.

**The `app_*` tools walk form ownership.** They cannot reach an add-in's frame that is parented
into an IDE window without being owned by it — no `form` name will find it, because `tree`
enumerates `Screen.Forms` and each form's *owned* components. To establish that an add-in BPL is
loaded at all, **enumerate the modules of the `bds.exe` process** and look for the BPL by name.
That is a fact about the process rather than about the VCL ownership graph, so it answers a
question the automation server cannot.

**The main menu is not reachable** as menu-item components; it is custom-drawn. Use `Alt`
accelerators via keystrokes, and screenshot the open menu to read it rather than guessing, since
shortcuts vary by keymap.

**Rebuild and re-register after a RAD Studio upgrade.** The BPL is version-suffixed and the
registration is per-version.

**Check which build is loaded before debugging a misbehaving one:**

```powershell
(Get-Item "$env:PUBLIC\Documents\Embarcadero\Studio\37.0\Bpl\Win64\gllIdeAutomation370.bpl").VersionInfo.FileVersion
```

**Leaving the package installed costs nothing** — it is inert unless the gate is set. The real
decision is whether to set the variable permanently: a reasonable trade on a development machine,
a poor one on a shared box. The server unit's own header says it outright — it must never be
started in a shipped application, and that is a discipline on the consumer's side, not something
the package can enforce.

---

## 15. Where to go next

| You want | Read |
|---|---|
| a command's exact fields, or an error code | [Help.md](Help.md) |
| why the package exists and what the tools do | [README.md](README.md) |
| what changed and when | [CHANGELOG.md](CHANGELOG.md) |

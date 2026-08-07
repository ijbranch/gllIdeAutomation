# Users Guide

How to drive the Delphi IDE from outside it. For things that have gone wrong, see
[HELP.md](HELP.md).

---

## The idea

The Delphi IDE is a VCL application. Its windows are `TForm` descendants owned by components with
names, exposing published properties, wired to `TAction`s and `TMenuItem`s — the same model your
own applications use. This package starts a small server inside the IDE that exposes that model
over a loopback socket.

So instead of synthesising keystrokes and reading pixels, you ask the IDE what it has and tell it
what to do:

```
{ "cmd":"tree" }                                  → every open form
{ "cmd":"tree", "form":"LocalVarsWindow" }        → its components and their properties
{ "cmd":"get", "form":"LocalVarsWindow", "name":"cbContext", "prop":"Text" }
{ "cmd":"click", "form":"LocalVarsWindow", "name":"lvCopyValue" }
```

It knows nothing about the IDE specifically. It walks `Screen.CustomForms`, so plugin windows —
GExperts, TestInsight, whatever you have — appear alongside the IDE's own.

---

## Getting it running

**1. Build** for the bitness of your IDE. `bin64\bds.exe` needs the Win64 build, `bin\bds.exe`
needs Win32. A design-time package must match the IDE loading it, and the wrong one simply never
loads.

**2. Install** — Component > Install Packages > Add, and choose the BPL.

**3. Enable.** Installing does not start anything. The server runs only when
`GITLAK_IDE_AUTOMATION` is `1` in the environment the IDE was launched from:

```powershell
$env:GITLAK_IDE_AUTOMATION = '1'
Start-Process 'C:\Program Files (x86)\Embarcadero\Studio\37.0\bin64\bds.exe'
```

or permanently, so every IDE is drivable:

```powershell
[Environment]::SetEnvironmentVariable('GITLAK_IDE_AUTOMATION','1','User')
```

`tools/Start-IDE.ps1` does the launch and tells you whether the server came up.

**4. Find it.** Each running instance writes
`C:\ProgramData\GITLAK\Automation\<pid>.json`:

```json
{ "app":"DelphiIDE", "pid":7948, "port":8730, "token":"{7FAF15B3-…}", "started":"2026-08-08T08:53:09+10:00" }
```

Ports are scanned upward from 8730, so two IDEs get different ones — always read the port from
the file. The file is deleted on clean shutdown; a leftover means the IDE died, so check the PID
is alive before trusting it.

---

## Talking to it

Loopback TCP, one JSON object per line, one line back. Every request carries the token.

```json
{ "token":"{7FAF15B3-…}", "id":1, "cmd":"get", "form":"LocalVarsWindow", "name":"cbContext", "prop":"Text" }
{ "id":1, "ok":true, "result":{ "name":"cbContext", "prop":"Text", "value":"TestVisualizers" } }
{ "id":1, "ok":false, "error":{ "code":"NoComp", "message":"component \"x\" not found on LocalVarsWindow" } }
```

**Addressing.** `form` is a form's `Name`, or `"main"`, or `"active"`; omitted means `main`.
`name` is a component **owned** by that form — ownership, not parenting. Omit `name` to address
the form itself.

### Commands

| cmd | fields | does |
|---|---|---|
| `ping` / `info` | — | `{ app, pid, version, exe, mainForm, server }` |
| `tree` | `form?` | no form: every open form. With a form: its components and their key published properties |
| `get` | `form?`, `name?`, `prop` | reads any published property, typed |
| `set` | `form?`, `name?`, `prop`, `value` | writes a published property and reads it back |
| `click` | `form?`, `name`, `mode?` | fires the component's `OnClick`. `mode=message` posts `BM_CLICK` instead and replies immediately — use it when the handler opens a modal dialog |
| `action` | `form?`, `name` | executes a `TAction` (or the action on a named control). Covers commands with no clickable control |
| `dialogs` | `button?` | lists open windows and their visible enabled buttons; with `button`, clicks the first match. Runs off the VCL thread, so it works while a modal loop is blocking |
| `wait_for` | `form?`, `name?`, `prop`, `value`, `op?`, `timeoutms?` | blocks until a property satisfies a comparison |
| `screenshot` | `area?` | PNG to the Desktop. Default is the monitor the active form is on; `"window"` or `"virtual"` also accepted |
| `dataset` | `form?`, `name`, `fields?` | state of a `TDataSet` |
| `field_get` | `form?`, `name`, `field` | one field's value from a `TDataSet` or `TDataSource` |

Failures return a stable `code`: `NoForm`, `NoComp`, `NoProp`, `NoHandler`, `Unauthorised`.

### From PowerShell

```powershell
$d = Get-Content (Get-ChildItem 'C:\ProgramData\GITLAK\Automation\*.json')[0].FullName -Raw |
     ConvertFrom-Json
$c = New-Object Net.Sockets.TcpClient('127.0.0.1', $d.port)
$s = $c.GetStream(); $w = New-Object IO.StreamWriter($s); $r = New-Object IO.StreamReader($s)
$w.WriteLine((@{ token=$d.token; id=1; cmd='tree' } | ConvertTo-Json -Compress)); $w.Flush()
$r.ReadLine() | ConvertFrom-Json
```

### From Python

`tools/read_pane.py` contains a 10-line client worth copying:

```python
def command(port, token, **fields):
    payload = json.dumps({"token": token, "id": 1, **fields}) + "\n"
    with socket.create_connection(("127.0.0.1", port), timeout=10) as s:
        s.sendall(payload.encode("utf-8"))
        buf = b""
        while not buf.endswith(b"\n"):
            buf += s.recv(4096)
    return json.loads(buf.decode("utf-8"))
```

Read the discovery file with `encoding="utf-8-sig"` — it is written with a BOM, and plain
`utf-8` makes `json.load` throw.

---

## Recipes

**What is open?** `{"cmd":"tree"}`. Expect around 48 forms on a stock IDE. Many exist but are
invisible until first used.

**Which stack frame is Local Variables showing?**
`{"cmd":"get","form":"LocalVarsWindow","name":"cbContext","prop":"Text"}`. Worth checking before
concluding a pane is empty — a stray keystroke in that combo changes the frame and empties the
list, which looks exactly like a broken debugger.

**Invoke a command that has no button.** Use `action` with the `TAction`'s name, which is how
menu and toolbar commands are wired.

**Answer a modal dialog.** `{"cmd":"click", "name":"btnSave", "mode":"message"}` to post the
click and return, then `{"cmd":"dialogs","button":"Yes"}`.

**Screenshot.** `{"cmd":"screenshot"}` writes a PNG to the Desktop and returns its path.

---

## Reading the debugger panes

`get` cannot read Local Variables or the Watch window. Both are `TVirtualStringTree`, and cell
text is not a published property. Neither is the selection.

The way round is the panes' own popup items, which *are* addressable components: select a row
with a real mouse click, then fire Copy Value and read the clipboard.

```
python tools/read_pane.py 300 1335
'TBaseThing(Name=base)'

python tools/read_pane.py 300 1335 --name
Base
```

`--pane watch` for the Watch window. Note the two panes do not share naming: Locals has
`lvCopyValue` / `lvCopyName`, Watch has `CopyWatchValue` / `CopyWatchName`. Confirm with `tree`
rather than assuming symmetry.

**Take coordinates from a fresh screenshot each time.** Row positions move whenever a node is
expanded or the pane is resized, and a stale coordinate reads a *different row* perfectly
happily — it does not fail, it answers the wrong question. Reading `--name` as well as the value
costs one extra call and catches it.

---

## Clicking and scaling

Selecting a tree row needs a genuine mouse click. `tools/click.py` does it, and there is one trap
that will cost you an afternoon if you write your own.

**On a scaled display there are two coordinate spaces.** With two 4K monitors at 150%:

| | Space | Size |
|---|---|---|
| `CopyFromScreen` screenshots | **physical** — it crops, it does not scale | 7680x2160 |
| `SetCursorPos` from a DPI-*unaware* process | **virtualised** | 5120x1440 |

They differ by exactly the scaling factor. Feed a coordinate read off a screenshot straight into
`SetCursorPos` from an unaware process and the click lands two thirds of the way to the target —
**silently**. `SendInput` returns success, and nothing happens. Declare
`PER_MONITOR_AWARE_V2` before touching the cursor and both spaces become physical.

Two further points, both learned by getting them wrong:

- **Button events with no coordinates apply wherever the cursor is at that instant.** If a human
  moves the mouse between your move and your click, the click lands in their window. `click.py`
  verifies the cursor stayed put immediately before each press and aborts otherwise.
- On Windows, injecting input via PowerShell `Add-Type` with P/Invoke may be blocked by AMSI as
  suspicious script content. Python `ctypes` is not scanned the same way.

---

## What it cannot do

- **Read VirtualStringTree contents** — Locals, Watch, the Structure pane. Not published. Use the
  Copy Value route above, or a screenshot.
- **Drive the main menu.** It is custom-drawn and does not surface as menu items. Use `Alt`
  accelerators via keystrokes, and screenshot the open menu to read them rather than guessing —
  shortcuts vary by keymap.
- **FireMonkey.** The server walks `TControl`/`TWinControl` and `Screen.CustomForms`.

---

## Safety

Loopback only, and every command needs the per-session token from the discovery file. There is no
remote surface.

But be clear-eyed: this can click buttons and set properties in your IDE. It is off unless you
set the environment variable, and that default is deliberate. Turning it on permanently is a
reasonable trade on a development machine and a poor one on a shared or production box.

It is also, by design, useless in a shipped application: the server should never be started in
anything a customer runs. That is a conditional-compilation and opt-in discipline on your side,
not something this package can enforce for you.

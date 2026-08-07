# gllIdeAutomation

A design-time package that starts the GITLAK automation server **inside the Delphi IDE**, so the
`app_*` agent tools can drive the IDE the way they already drive the DBi* applications.

It is deliberately tiny. `gllAutomationServer` is already compiled into `GITLAKLib370.bpl`, and
the IDE already loads that package — so the server code is *already in the IDE process*. Nobody
was calling `Start`. That is all this package does.

## Installing

1. Build Win64 (Debug and Release) — output is
   `C:\Users\Public\Documents\Embarcadero\Studio\37.0\Bpl\Win64\gllIdeAutomation370.bpl`.
2. Register it: **Component > Install Packages > Add**, or add a value to
   `HKCU\Software\Embarcadero\BDS\37.0\Known Packages x64` whose *name* is the full BPL path and
   whose *value* is the description.

Note the `x64` list — that is the one the 64-bit IDE reads. The plain `Known Packages` list is
for the 32-bit IDE and this package is Win64 only.

## Running

The server does **not** start just because the package is installed. It starts only when the
environment variable `GITLAK_IDE_AUTOMATION` is `1`:

```powershell
$env:GITLAK_IDE_AUTOMATION = '1'
Start-Process 'C:\Program Files (x86)\Embarcadero\Studio\37.0\bin64\bds.exe' `
  -ArgumentList '/highdpi:unaware'
```

An IDE started any other way — Start menu, file association, anything that does not deliberately
set that variable — is completely unaffected. The IDE then appears in `app_list` as **DelphiIDE**.

### Why an environment variable rather than `/AUTOMATION`

The DBi apps gate on the `/AUTOMATION` command-line switch. That would be wrong here: `bds.exe`
parses its own command line and treats arguments it does not recognise as files to open.

## What it is good for, and what it is not

**Good for:** driving menus, actions, dialogs and controls through the live VCL component model.
That is far more reliable than synthesising keystrokes — coordinate-free, DPI-independent, and it
cannot type into the wrong window, which is the standing hazard of a `SendKeys` approach.

**Not directly good for:** reading the Local Variables or Watch panes. Those are
VirtualStringTree based — `app_tree LocalVarsWindow` shows `LocalsTreeView` exposing only
`Visible`/`Enabled`/`Left`/`Top`/`Width`/`Height` — so `app_get` cannot see cell text.

**But there is a way round it, and it works.** The panes' popup menu items are addressable
components — `lvCopyName`, `lvCopyValue`, `lvInspect`, `lvWatch`, `lvEvaluateModify`,
`lvVisualizers`. Select a row, fire `lvCopyValue`, read the clipboard:

```
python tools/click.py 300 1335 --activate <ide-pid>     # select the row
app_click DelphiIDE LocalVarsWindow lvCopyValue          # copy its value
powershell -c Get-Clipboard                              # 'TBaseThing(Name=base)'
```

Verified 2026-08-08 on two different rows, each returning exactly what the pane displayed. So a
debugger value **can** be had as text rather than as pixels.

Selection is the part that needs a real mouse click: `app_click LocalsTreeView` fails with
`OnClick is not assigned`, selection is not a published property, and keyboard focus will not
reach the tree. Hence `tools/click.py`.

### The coordinate trap that cost an hour

Ian runs two 4K monitors at **150%**, so there are two coordinate spaces and they differ by
exactly 1.5:

| | Space | Size |
|---|---|---|
| `CopyFromScreen` screenshots | **physical** (it crops, it does not scale) | 7680x2160 |
| `SetCursorPos` from a DPI-*unaware* process | **virtualised** | 5120x1440 |

Click at a coordinate read off a screenshot without accounting for that and you land two thirds
of the way to the target, silently — `SendInput` returns success and nothing happens.
`tools/click.py` declares `PER_MONITOR_AWARE_V2` at startup, which puts `SetCursorPos` into
physical coordinates so it matches the screenshots 1:1.

It also refuses to click if the cursor will not stay where it was put, because a human moving the
mouse would otherwise take the click in their own window.

## Safety

- **Gated off by default** — see above.
- **`initialization` cannot throw.** An exception escaping a design-time package's initialisation
  is reported to the user as a package load failure, for a facility they did not ask for. A port
  clash or an unwritable discovery directory must cost the automation server, never the IDE.
- **`finalization` cannot throw either**, so a failure while closing cannot become a shutdown hang.
- **GITLAKLib is not modified.** That library carries a v4.0.0 compatibility commitment and its
  source is held by an outside developer under NDA; this package only *requires* it.

## Uninstalling

Remove the value from `Known Packages x64` (or untick it in Component > Install Packages) and
restart the IDE. Nothing else is left behind — the server writes a discovery file under
`C:\ProgramData\GITLAK\Automation\` while running and deletes it on clean shutdown.

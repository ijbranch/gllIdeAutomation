# Help — quick answers

Short answers to the things that go wrong. For how to *use* it, see
[Users Guide.md](Users%20Guide.md).

## The IDE does not appear in the discovery directory

The server is not running. Work down this list:

1. **Was the gate set in the launching environment?**
   `[Environment]::GetEnvironmentVariable('GITLAK_IDE_AUTOMATION','User')` should be `1`, or the
   variable must be set in the shell you launched from. Setting it *after* the IDE started has no
   effect — a process gets its environment at creation.
2. **Is the package installed and enabled?** Component > Install Packages; look for
   *IDE Automation*. If the tick is cleared, the IDE loaded it and then disabled it, which means
   it failed to load — see below.
3. **Is it the right bitness?** A design-time package must match the IDE that loads it. `bin64\bds.exe`
   needs the Win64 build; `bin\bds.exe` needs Win32. The wrong one silently never loads.
4. **Is the process really the IDE you think?** Two IDEs can be running. Check the PID in the
   discovery file against `Get-Process bds`.

## It worked yesterday and now it does not

Almost always one of:

- **A RAD Studio update.** The BPL is version-suffixed and the registration is per-version.
  Rebuild and re-register.
- **The IDE is loading an older build than the one you just made.** The BPL carries version
  information, so check rather than assume:

  ```powershell
  (Get-Item "$env:PUBLIC\Documents\Embarcadero\Studio\37.0\Bpl\Win64\gllIdeAutomation370.bpl").VersionInfo.FileVersion
  ```

  If that number has not moved since your last change, the build did not reach the BPL the IDE
  loads. Nothing advances that number on its own — it lives in `gllIdeAutomationVersion.rc` and
  changes only when you run `python tools/bump-build.py`. So two builds you did not bump between
  will legitimately report the same version.
- **The IDE was launched from somewhere that does not carry the environment variable** — a
  shortcut, a file association, another tool launching it.
- **A stale discovery file** from an IDE that died without cleaning up. The file names itself
  after the PID, so a client that does not check whether the PID is alive can chase a dead one.

## "Port already in use" or the server picks an odd port

The server scans upward from 8730 for a free port. Two IDEs running with the gate set will get
different ports, which is intended — read the port from the discovery file rather than assuming
8730.

## A command returns `Unauthorised`

Every command must carry the `token` from that instance's discovery file. The token is
per-session: it changes each time the IDE restarts, so a cached one goes stale.

## A command returns `NoComp` / `NoForm` / `NoProp`

- `NoForm` — the form name is wrong, or the form does not exist yet. Send `tree` with no `form`
  to list what is actually open. Many IDE windows exist but are not visible until first used.
- `NoComp` — the component is not *owned* by that form. Ownership is not the same as parenting;
  send `tree` with the form name to see the owned components.
- `NoProp` — the property is not published. This is the usual wall: `TVirtualStringTree` cell
  text, tree selection and grid contents are not published and cannot be read this way.

## `click` says "OnClick is not assigned"

`click` fires the component's `OnClick` handler. If the control does not have one — most trees,
grids and panels — there is nothing to fire. That is not a bug in the control; the interaction
you are trying to reproduce is probably mouse-position dependent, so use `tools/click.py`.

## The click goes to the wrong place

Read the coordinate-trap section in the [Users Guide](Users%20Guide.md#clicking-and-scaling).
On a scaled display, screenshots and cursor positions are in *different* coordinate spaces, and
a mis-scaled click fails silently rather than erroring.

Also: `click.py` aborts rather than clicking if the cursor will not stay where it was put. If you
see that message, something else is moving the mouse — usually a human.

## Copy Value produces nothing

No row is selected. Firing the popup item does not select anything; it acts on the current
selection, and an empty selection means an empty clipboard. Click the row first.

`read_pane.py` distinguishes the two cases for you by priming the clipboard with a sentinel, so
"nothing was copied" and "the value is genuinely empty" do not look identical.

## The IDE hangs when a command runs

A command whose handler opens a modal dialog will block until the dialog closes, because the
reply waits for the handler to return. Use `mode=message` on `click` for button-class controls,
which posts the click and replies immediately, then answer the dialog with the `dialogs`
command.

## Building the package fails with two errors

If the IDE has the package installed, it holds both build outputs open — `gllIdeAutomation370.bpl`
(the number is the version suffix) and `gllIdeAutomation.dcp`. A build cannot replace a file that
is loaded, so you get two `F2039 Could not create output file` errors in the Messages pane, one per
output. The count is the giveaway: two errors, no compilation errors, and the compiler reports the
unit count normally.

Either untick the package in **Component > Install Packages**, build, and re-tick it; or build from
the command line with the IDE closed. The same lock is why an MSBuild or `dcc64` build fails while
an IDE has the package loaded — it is not specific to building from inside the IDE.

## Should I leave this installed?

The package is inert unless the environment variable is set, so leaving it installed costs
nothing. Whether to set the variable permanently is the real question: convenience against
having a loopback listener in your IDE whenever it runs. It is token-authenticated and bound to
127.0.0.1, but it is still a facility that can click things in your editor. Decide deliberately.

## Reporting a problem

Include: Delphi version and bitness, whether the discovery file exists, the exact JSON you sent
and the exact reply, and — for anything involving clicks — your display scaling.

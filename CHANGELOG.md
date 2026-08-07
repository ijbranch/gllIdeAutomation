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
- Gated on the `GITLAK_IDE_AUTOMATION=1` environment variable, so an IDE launched any other way
  is unaffected. **Why not `/AUTOMATION`,** as the DBi apps use: `bds.exe` parses its own command
  line and treats unrecognised arguments as files to open. (2026-08-08) —
  `u_gllIdeAutomationStarter.pas`

(*
  gllIdeAutomation - in-IDE automation server

  Copyright (c) 2016-2026 Ian Branch (GITLAK Software)
  Licensed under the MIT Licence - see LICENSE at the root of this repository.

  The commands here are the ones that need the ToolsAPI, kept out of gllIdeAutomation.Server so
  that unit stays a VCL-only copy of GITLAKLib's gllAutomationServer. They register themselves
  through TAutomationServer.RegisterCommand.

  PROVENANCE: the command set was chosen after reading GxInspect (GExperts' inspection server,
  ^/GxInspect/trunk), whose README documents what each of these IDE operations really does when
  measured. That behaviour - not its source, which is MPL - is what was taken: every line below
  was written here against ToolsAPI.pas. The findings that shaped a command are cited at the
  command.
*)
/// <summary>
///   ToolsAPI commands for the in-IDE automation server: closing the IDE without it stopping to
///   ask, walking and clicking the main menu, and driving the IDE's own debugger.
/// </summary>
unit gllIdeAutomation.IdeCommands;

{$IF CompilerVersion < 33.0}
  {$MESSAGE FATAL 'gllIdeAutomation requires Delphi 10.3 Rio or later.'}
{$IFEND}

interface

/// <summary>
///   Registers every command in this unit with the automation server and installs the debugger
///   notifier the waiting commands rely on. Call once, on the main thread, after the server started.
/// </summary>
procedure RegisterIdeCommands;

/// <summary>Removes the commands and the debugger notifier again. Safe to call when never registered.</summary>
procedure UnregisterIdeCommands;

implementation

uses
  System.SysUtils, System.StrUtils, System.Classes, System.JSON, System.TypInfo, System.SyncObjs, System.Diagnostics,
  System.Generics.Collections,
  Winapi.Windows,
  Vcl.Forms, Vcl.Menus,
  ToolsAPI,
  gllIdeAutomation.Server;

const
  /// <summary>How long <c>ide_quit</c> and <c>ide_menu_click</c> wait before acting, so their answer is on the wire first.</summary>
  DEFER_MS            = 150;
  /// <summary>Default wait, in milliseconds, of a step or run-to for the process to stop again.</summary>
  STEP_WAIT_MS        = 10000;
  /// <summary>Upper bound on any <c>wait</c> argument; a mistyped one must not hold a connection for an hour.</summary>
  MAX_WAIT_MS         = 120000;
  /// <summary>Polling step while waiting for the debugger to report a stop.</summary>
  WAIT_POLL_MS        = 20;
  /// <summary>Default number of call-stack frames returned.</summary>
  STACK_DEFAULT_MAX   = 100;
  /// <summary>Default number of bytes <c>debug_memory</c> reads.</summary>
  MEMORY_DEFAULT      = 64;
  /// <summary>Upper bound on the bytes <c>debug_memory</c> reads in one request.</summary>
  MEMORY_MAX          = 4096;
  /// <summary>Size, in characters, of the buffer the evaluator writes its result into.</summary>
  EVAL_BUFFER_CHARS   = 65536;
  /// <summary>Deepest menu branch <c>ide_menu</c> will expand.</summary>
  MENU_MAX_DEPTH      = 6;

  /// <summary>Process states in which the debugger has the process stopped and will answer about it.</summary>
  STOPPED_STATES      = [ psStopped, psFault, psResFault, psException ];
  /// <summary>Process states that end a wait: stopped, or gone.</summary>
  WAIT_END_STATES     = STOPPED_STATES + [ psTerminated, psNoProcess ];

  /// <summary>Every command this unit registers, so that unregistering cannot miss one.</summary>
  COMMAND_NAMES: array[ 0..20 ] of string = (
    'ide_modified', 'ide_quit', 'ide_menu', 'ide_menu_click',
    'debug_state', 'debug_attach', 'debug_detach', 'debug_pause', 'debug_run', 'debug_step',
    'debug_run_to', 'debug_terminate', 'debug_threads', 'debug_set_thread', 'debug_stack',
    'debug_registers', 'debug_memory', 'debug_eval', 'debug_breakpoints', 'debug_breakpoint_set',
    'debug_breakpoint_delete' );

type
  /// <summary>
  ///   Counts the debugger's stops, so that a command on a worker thread can wait for the next one.
  ///   The IDE calls it on the main thread; the count is read from worker threads.
  /// </summary>
  TStopWatcher = class( TNotifierObject, IOTADebuggerNotifier, IOTADebuggerNotifier90 )
  public
    /// <summary>Not used.</summary>
    /// <param name="Process">The new process.</param>
    procedure ProcessCreated( const Process: IOTAProcess );
    /// <summary>Counts as a stop: a waiter must not sit out its timeout for a process that has gone.</summary>
    /// <param name="Process">The process that ended.</param>
    procedure ProcessDestroyed( const Process: IOTAProcess );
    /// <summary>Not used.</summary>
    /// <param name="Breakpoint">The breakpoint.</param>
    procedure BreakpointAdded( const Breakpoint: IOTABreakpoint );
    /// <summary>Not used.</summary>
    /// <param name="Breakpoint">The breakpoint.</param>
    procedure BreakpointDeleted( const Breakpoint: IOTABreakpoint );
    /// <summary>Not used.</summary>
    /// <param name="Breakpoint">The breakpoint.</param>
    procedure BreakpointChanged( const Breakpoint: IOTABreakpoint );
    /// <summary>Not used.</summary>
    /// <param name="Process">The now-current process.</param>
    procedure CurrentProcessChanged( const Process: IOTAProcess );
    /// <summary>Counts a stop whenever the new state is one that ends a wait.</summary>
    /// <param name="Process">The process whose state changed.</param>
    procedure ProcessStateChanged( const Process: IOTAProcess );
    /// <summary>Lets every launch go ahead.</summary>
    /// <param name="Project">The project being launched.</param>
    /// <returns>Always True.</returns>
    function  BeforeProgramLaunch( const Project: IOTAProject ): Boolean;
    /// <summary>Not used.</summary>
    procedure ProcessMemoryChanged;
  end;

  /// <summary>One entry of the list of what the IDE holds unsaved.</summary>
  TModifiedEntry = record
    /// <summary>The file, or the project file when <c>Kind</c> is <c>options</c>.</summary>
    FileName : string;
    /// <summary><c>buffer</c> for an edited file, <c>options</c> for changed project options.</summary>
    Kind     : string;
    /// <summary>True when the file does not exist on disk yet, so saving it would open Save As.</summary>
    Untitled : Boolean;
    /// <summary>The module holding it.</summary>
    Module   : IOTAModule;
    /// <summary>The module's own file name, captured up front: a closed module must not be asked for it.</summary>
    ModuleFileName : string;
  end;

var
  /// <summary>Number of stops seen so far; only ever incremented. See <see cref="TStopWatcher"/>.</summary>
  GStopGeneration   : Integer = 0;
  /// <summary>Index the debugger returned for our notifier, or -1 while none is installed.</summary>
  GNotifierIndex    : Integer = -1;

{ ── TStopWatcher ────────────────────────────────────────────────────────── }

procedure TStopWatcher.ProcessCreated( const Process: IOTAProcess );
begin
end;

procedure TStopWatcher.ProcessDestroyed( const Process: IOTAProcess );
begin

  TInterlocked.Increment( GStopGeneration );

end;

procedure TStopWatcher.BreakpointAdded( const Breakpoint: IOTABreakpoint );
begin
end;

procedure TStopWatcher.BreakpointDeleted( const Breakpoint: IOTABreakpoint );
begin
end;

procedure TStopWatcher.BreakpointChanged( const Breakpoint: IOTABreakpoint );
begin
end;

procedure TStopWatcher.CurrentProcessChanged( const Process: IOTAProcess );
begin
end;

procedure TStopWatcher.ProcessStateChanged( const Process: IOTAProcess );
begin

  if Assigned( Process ) and ( Process.ProcessState in WAIT_END_STATES ) then
    TInterlocked.Increment( GStopGeneration );

end;

function TStopWatcher.BeforeProgramLaunch( const Project: IOTAProject ): Boolean;
begin

  Result := True;

end;

procedure TStopWatcher.ProcessMemoryChanged;
begin
end;

{ ── Helpers ─────────────────────────────────────────────────────────────── }

/// <summary>Reads the stop count from any thread.</summary>
/// <returns>The current value of <see cref="GStopGeneration"/>.</returns>
function StopGeneration: Integer;
begin

  Result := TInterlocked.CompareExchange( GStopGeneration, 0, 0 );

end;

/// <summary>
///   Reads an optional argument, keeping <paramref name="ADefault"/> when it is absent.
///   <c>TJSONValue.TryGetValue</c> cannot be used for this on its own: it sets its out parameter to
///   <c>Default( T )</c> when the key is missing, so a default assigned beforehand is silently replaced
///   by False, 0 or ''. That once made every new breakpoint come out disabled.
/// </summary>
/// <param name="AReq">The request.</param>
/// <param name="AKey">The argument's name.</param>
/// <param name="ADefault">The value when the argument is absent.</param>
/// <returns>The argument, or <paramref name="ADefault"/>.</returns>
/// <exception cref="EAutoError"><c>BadRequest</c> when the argument is present but not a string.</exception>
function OptString( AReq: TJSONObject; const AKey, ADefault: string ): string;
begin

  if AReq.GetValue( AKey ) = nil then Exit( ADefault );
  if not AReq.TryGetValue<string>( AKey, Result ) then
    raise EAutoError.CreateCode( 'BadRequest', Format( '"%s" must be a string', [ AKey ] ) );

end;

/// <summary>Reads an optional integer argument; see <see cref="OptString"/> for why this is not a bare TryGetValue.</summary>
/// <param name="AReq">The request.</param>
/// <param name="AKey">The argument's name.</param>
/// <param name="ADefault">The value when the argument is absent.</param>
/// <returns>The argument, or <paramref name="ADefault"/>.</returns>
/// <exception cref="EAutoError"><c>BadRequest</c> when the argument is present but not a number.</exception>
function OptInteger( AReq: TJSONObject; const AKey: string; ADefault: Integer ): Integer;
begin

  if AReq.GetValue( AKey ) = nil then Exit( ADefault );
  if not AReq.TryGetValue<Integer>( AKey, Result ) then
    raise EAutoError.CreateCode( 'BadRequest', Format( '"%s" must be a number', [ AKey ] ) );

end;

/// <summary>Reads an optional Boolean argument; see <see cref="OptString"/> for why this is not a bare TryGetValue.</summary>
/// <param name="AReq">The request.</param>
/// <param name="AKey">The argument's name.</param>
/// <param name="ADefault">The value when the argument is absent.</param>
/// <returns>The argument, or <paramref name="ADefault"/>.</returns>
/// <exception cref="EAutoError"><c>BadRequest</c> when the argument is present but not true or false.</exception>
function OptBoolean( AReq: TJSONObject; const AKey: string; ADefault: Boolean ): Boolean;
begin

  if AReq.GetValue( AKey ) = nil then Exit( ADefault );
  if not AReq.TryGetValue<Boolean>( AKey, Result ) then
    raise EAutoError.CreateCode( 'BadRequest', Format( '"%s" must be true or false', [ AKey ] ) );

end;

/// <summary>Reads a required string argument.</summary>
/// <param name="AReq">The request.</param>
/// <param name="AKey">The argument's name.</param>
/// <param name="ACommand">The command, for the message.</param>
/// <returns>The value, never empty.</returns>
/// <exception cref="EAutoError"><c>BadRequest</c> when the argument is missing or empty.</exception>
function NeedString( AReq: TJSONObject; const AKey, ACommand: string ): string;
begin

  Result := '';
  AReq.TryGetValue<string>( AKey, Result );
  if Trim( Result ) = '' then
    raise EAutoError.CreateCode( 'BadRequest', Format( '%s needs "%s"', [ ACommand, AKey ] ) );

end;

/// <summary>Reads a required integer argument.</summary>
/// <param name="AReq">The request.</param>
/// <param name="AKey">The argument's name.</param>
/// <param name="ACommand">The command, for the message.</param>
/// <returns>The value.</returns>
/// <exception cref="EAutoError"><c>BadRequest</c> when the argument is missing or not a number.</exception>
function NeedInteger( AReq: TJSONObject; const AKey, ACommand: string ): Integer;
begin

  if not AReq.TryGetValue<Integer>( AKey, Result ) then
    raise EAutoError.CreateCode( 'BadRequest', Format( '%s needs "%s", a number', [ ACommand, AKey ] ) );

end;

/// <summary>Reads the optional <c>wait</c> argument, clamped to 0..<c>MAX_WAIT_MS</c>.</summary>
/// <param name="AReq">The request.</param>
/// <param name="ADefault">The value when the argument is absent.</param>
/// <returns>The wait in milliseconds.</returns>
function WaitArgument( AReq: TJSONObject; ADefault: Integer ): Integer;
begin

  Result := OptInteger( AReq, 'wait', ADefault );
  if Result < 0 then Result := 0;
  if Result > MAX_WAIT_MS then Result := MAX_WAIT_MS;

end;

/// <summary>
///   Runs <paramref name="AProc"/> on the main thread after a short delay, so that the answer to the
///   command that scheduled it has been written before it runs. A menu command that opens a modal
///   dialog would otherwise hold the answer until somebody closed the dialog.
/// </summary>
/// <param name="AProc">What to run.</param>
procedure DeferToMainThread( const AProc: TThreadProcedure );
begin

  TThread.CreateAnonymousThread(
    procedure
    begin
      Sleep( DEFER_MS );
      TThread.Queue( nil, AProc );
    end ).Start;

end;

/// <summary>Formats an address or register as 16 hex digits.</summary>
/// <param name="AValue">The value.</param>
/// <returns>For example <c>00000000004A1F30</c>.</returns>
function Hex64( AValue: UInt64 ): string;
begin

  Result := IntToHex( AValue, 16 );

end;

/// <summary>The name of an enumeration value without its lower-case prefix, e.g. <c>psStopped</c> gives <c>stopped</c>.</summary>
/// <param name="ATypeInfo">The enumeration's type information.</param>
/// <param name="AValue">The ordinal value.</param>
/// <returns>The name with its prefix removed and its first letter lower-cased.</returns>
function EnumText( ATypeInfo: PTypeInfo; AValue: Integer ): string;
begin

  Result := GetEnumName( ATypeInfo, AValue );
  var iStart := 1;
  while ( iStart <= Length( Result ) ) and CharInSet( Result[ iStart ], [ 'a'..'z' ] ) do
    Inc( iStart );
  if iStart <= Length( Result ) then
  begin
    Result := Copy( Result, iStart, MaxInt );
    Result[ 1 ] := LowerCase( Result[ 1 ] )[ 1 ];
  end;

end;

/// <summary>The IDE's module services.</summary>
/// <returns>The service.</returns>
/// <exception cref="EAutoError"><c>NoService</c> when the IDE does not offer it.</exception>
function ModuleServices: IOTAModuleServices;
begin

  if not Supports( BorlandIDEServices, IOTAModuleServices, Result ) then
    raise EAutoError.CreateCode( 'NoService', 'The IDE offers no module services' );

end;

/// <summary>The IDE's debugger services.</summary>
/// <returns>The service.</returns>
/// <exception cref="EAutoError"><c>NoService</c> when the IDE does not offer it.</exception>
function DebuggerServices: IOTADebuggerServices;
begin

  if not Supports( BorlandIDEServices, IOTADebuggerServices, Result ) then
    raise EAutoError.CreateCode( 'NoService', 'The IDE offers no debugger services' );

end;

{ ── ide_modified / ide_quit ─────────────────────────────────────────────── }

/// <summary>
///   Everything the IDE would stop and ask about on closing: every edited file, and every project
///   whose options changed. A project group that has never been saved is left out - the IDE
///   invents one round a single project, never saves it and never asks about it (GxInspect,
///   measured over four closes).
/// </summary>
/// <returns>The list, possibly empty.</returns>
function CollectModified: TArray<TModifiedEntry>;
begin

  var oList := TList<TModifiedEntry>.Create;
  try
    var oServices := ModuleServices;
    for var iModule := 0 to oServices.ModuleCount - 1 do
    begin
      var oModule := oServices.Modules[ iModule ];
      if Supports( oModule, IOTAProjectGroup ) and not FileExists( oModule.FileName ) then
        Continue;

      for var iFile := 0 to oModule.ModuleFileCount - 1 do
      begin
        var oEditor := oModule.ModuleFileEditors[ iFile ];
        if Assigned( oEditor ) and oEditor.Modified then
        begin
          var rEntry: TModifiedEntry;
          rEntry.FileName := oEditor.FileName;
          rEntry.Kind     := 'buffer';
          rEntry.Untitled := not FileExists( oEditor.FileName );
          rEntry.Module   := oModule;
          rEntry.ModuleFileName := oModule.FileName;
          oList.Add( rEntry );
        end;
      end;

      var oProject: IOTAProject;
      if Supports( oModule, IOTAProject, oProject ) and Assigned( oProject.ProjectOptions ) and
        oProject.ProjectOptions.ModifiedState then
      begin
        var rEntry: TModifiedEntry;
        rEntry.FileName := oProject.FileName;
        rEntry.Kind     := 'options';
        rEntry.Untitled := not FileExists( oProject.FileName );
        rEntry.Module   := oModule;
        rEntry.ModuleFileName := oModule.FileName;
        oList.Add( rEntry );
      end;
    end;

    Result := oList.ToArray;
  finally
    oList.Free;
  end;

end;

/// <summary>Renders the modified list as JSON.</summary>
/// <param name="AEntries">The entries.</param>
/// <returns>An array of <c>{ file, kind, untitled }</c>.</returns>
function ModifiedToJSON( const AEntries: TArray<TModifiedEntry> ): TJSONArray;
begin

  Result := TJSONArray.Create;
  for var rEntry in AEntries do
  begin
    var oItem := TJSONObject.Create;
    Result.AddElement( oItem );
    oItem.AddPair( 'file', rEntry.FileName );
    oItem.AddPair( 'kind', rEntry.Kind );
    oItem.AddPair( 'untitled', TJSONBool.Create( rEntry.Untitled ) );
  end;

end;

/// <summary><c>ide_modified</c>: what the IDE holds unsaved, without closing anything.</summary>
/// <param name="AReq">The request (no arguments).</param>
/// <returns><c>{ count, modified:[ { file, kind, untitled } ] }</c>.</returns>
function CmdIdeModified( AReq: TJSONObject ): TJSONValue;
begin

  var aEntries := CollectModified;
  var oRes := TJSONObject.Create;
  oRes.AddPair( 'count', TJSONNumber.Create( Length( aEntries ) ) );
  oRes.AddPair( 'modified', ModifiedToJSON( aEntries ) );
  Result := oRes;

end;

/// <summary>
///   <c>ide_quit</c>: closes the IDE without leaving it waiting on a question nobody can answer.
///   The IDE's "save changes?" prompt is modal - in Delphi 13 a VCL <c>TMessageForm</c> captioned
///   "Confirm" (measured; GxInspect saw a plain API message box in older IDEs) - so a script that
///   reaches it waits for a human. So the default looks first and refuses instead.
/// </summary>
/// <param name="AReq">
///   The request: <c>mode</c> = <c>refuse</c> (default: close only when nothing is unsaved),
///   <c>save</c> (save everything first), <c>discard</c> (force-close every modified module, losing the
///   changes) or <c>ask</c> (close and let the IDE ask whatever it likes).
/// </param>
/// <returns><c>{ closing:true, mode, saved|discarded:[...] }</c>; the IDE closes shortly after the answer.</returns>
/// <exception cref="EAutoError">
///   <c>Modified</c> in refuse mode when anything is unsaved, with the list in <c>error.data</c>;
///   <c>Untitled</c> in save mode when a file has never been saved, since saving it opens Save As;
///   <c>SaveFailed</c> / <c>CloseFailed</c> when the IDE declined; <c>BadRequest</c> for an unknown mode.
/// </exception>
/// <remarks>
///   Prefer <c>discard</c> to <c>save</c> in scripts. The IDE modifies files merely by opening them - a
///   project is upgraded to the running IDE's version, and a form loses or gains properties such as
///   <c>OldCreateOrder</c> - so saving what it holds writes churn nobody asked for (GxInspect).
/// </remarks>
function CmdIdeQuit( AReq: TJSONObject ): TJSONValue;
begin

  var sMode := LowerCase( Trim( OptString( AReq, 'mode', 'refuse' ) ) );

  var aEntries := CollectModified;
  var oRes := TJSONObject.Create;
  try
    oRes.AddPair( 'mode', sMode );

    if sMode = 'refuse' then
    begin
      if Length( aEntries ) > 0 then
        raise EAutoError.CreateCodeData( 'Modified',
          Format( '%d unsaved item(s); closing would stop and ask. Use mode save, discard or ask', [ Length( aEntries ) ] ),
          ModifiedToJSON( aEntries ) );
    end
    else if sMode = 'save' then
    begin
      var oUntitled := TJSONArray.Create;
      try
        for var rEntry in aEntries do
          if rEntry.Untitled then
            oUntitled.Add( rEntry.FileName );
      except
        oUntitled.Free;
        raise;
      end;
      if oUntitled.Count > 0 then
        raise EAutoError.CreateCodeData( 'Untitled', 'These have never been saved, and saving them would open Save As',
          oUntitled );
      oUntitled.Free;

      //  One save per module: a form's .pas and .dfm are two entries of the same module.
      var oDone := TStringList.Create;
      try
        oDone.CaseSensitive := False;
        var oSaved := TJSONArray.Create;
        oRes.AddPair( 'saved', oSaved );
        for var rEntry in aEntries do
        begin
          if oDone.IndexOf( rEntry.ModuleFileName ) >= 0 then
            Continue;
          oDone.Add( rEntry.ModuleFileName );
          if not rEntry.Module.Save( False, True ) then
            raise EAutoError.CreateCode( 'SaveFailed', 'The IDE did not save ' + rEntry.ModuleFileName );
          oSaved.Add( rEntry.ModuleFileName );
        end;
      finally
        oDone.Free;
      end;
    end
    else if sMode = 'discard' then
    begin
      //  One close per module, and the module is found afresh each time: closing a project closes
      //  its units too, and an interface to a closed module must not be used again.
      var oDone := TStringList.Create;
      try
        oDone.CaseSensitive := False;
        var oDiscarded := TJSONArray.Create;
        oRes.AddPair( 'discarded', oDiscarded );
        for var rEntry in aEntries do
        begin
          if oDone.IndexOf( rEntry.ModuleFileName ) >= 0 then
            Continue;
          oDone.Add( rEntry.ModuleFileName );
          var oModule := ModuleServices.FindModule( rEntry.ModuleFileName );
          if oModule = nil then
            Continue;
          if not oModule.CloseModule( True ) then
            raise EAutoError.CreateCode( 'CloseFailed', 'The IDE did not close ' + rEntry.ModuleFileName );
          oDiscarded.Add( rEntry.ModuleFileName );
        end;
      finally
        oDone.Free;
      end;
    end
    else if sMode <> 'ask' then
      raise EAutoError.CreateCode( 'BadRequest', 'ide_quit mode is refuse, save, discard or ask' );

    DeferToMainThread(
      procedure
      begin
        if Assigned( Application.MainForm ) then
          Application.MainForm.Close;
      end );

    oRes.AddPair( 'closing', TJSONBool.Create( True ) );
    Result := oRes;
  except
    oRes.Free;
    raise;
  end;

end;

{ ── ide_menu / ide_menu_click ───────────────────────────────────────────── }

/// <summary>The IDE's main menu.</summary>
/// <returns>The menu.</returns>
/// <exception cref="EAutoError"><c>NoService</c> when the IDE offers no main menu.</exception>
function IdeMainMenu: TMainMenu;
begin

  var oServices: INTAServices;
  if not Supports( BorlandIDEServices, INTAServices, oServices ) or ( oServices.MainMenu = nil ) then
    raise EAutoError.CreateCode( 'NoService', 'The IDE offers no main menu' );
  Result := oServices.MainMenu;

end;

/// <summary>
///   Brings a submenu up to date the way opening it would: it is clicked when it already has items
///   (the IDE fills some submenus only then - View, Desktops for one), and every item is updated from
///   its action. Without the update XE3 reported File, Open From Version Control as hidden when it
///   was not (GxInspect).
/// </summary>
/// <param name="AItem">The submenu.</param>
procedure FillSubmenu( AItem: TMenuItem );
begin

  if AItem.Count > 0 then
    AItem.Click;
  for var iChild := 0 to AItem.Count - 1 do
    AItem.Items[ iChild ].InitiateAction;

end;

/// <summary>Describes one menu item, and its children to the given depth.</summary>
/// <param name="AItem">The item.</param>
/// <param name="ADepth">How many levels of children to include; 0 for none.</param>
/// <returns><c>{ name, caption, action?, enabled, visible, checked, separator, count, items? }</c>.</returns>
function MenuItemToJSON( AItem: TMenuItem; ADepth: Integer ): TJSONObject;
begin

  Result := TJSONObject.Create;
  Result.AddPair( 'name', AItem.Name );
  Result.AddPair( 'caption', AItem.Caption );
  if Assigned( AItem.Action ) and ( AItem.Action.Name <> '' ) then
    Result.AddPair( 'action', AItem.Action.Name );
  Result.AddPair( 'enabled', TJSONBool.Create( AItem.Enabled ) );
  Result.AddPair( 'visible', TJSONBool.Create( AItem.Visible ) );
  Result.AddPair( 'checked', TJSONBool.Create( AItem.Checked ) );
  Result.AddPair( 'separator', TJSONBool.Create( AItem.IsLine ) );
  Result.AddPair( 'count', TJSONNumber.Create( AItem.Count ) );

  if ( ADepth > 0 ) and ( AItem.Count > 0 ) then
  begin
    FillSubmenu( AItem );
    var oItems := TJSONArray.Create;
    Result.AddPair( 'items', oItems );
    for var iChild := 0 to AItem.Count - 1 do
      oItems.AddElement( MenuItemToJSON( AItem.Items[ iChild ], ADepth - 1 ) );
  end;

end;

/// <summary>The caption as a person reads it: without the accelerator ampersand.</summary>
/// <param name="AItem">The item.</param>
/// <returns>The stripped caption.</returns>
function PlainCaption( AItem: TMenuItem ): string;
begin

  Result := StripHotkey( AItem.Caption );

end;

/// <summary>
///   Finds one step of a menu path among a parent's items. A step is a component name or a caption;
///   a caption is compared without its ampersand and without case, and matches by its beginning when
///   nothing matches it whole - which names an item whose caption changes (a port number, say).
///   Names are the dependable choice in a localised IDE.
/// </summary>
/// <param name="AParent">The parent item.</param>
/// <param name="AStep">The step.</param>
/// <returns>The matching item.</returns>
/// <exception cref="EAutoError">
///   <c>NoMenuItem</c> when nothing matches, and <c>AmbiguousMenuItem</c> when a prefix matches several;
///   either carries the candidates in <c>error.data</c>.
/// </exception>
function FindMenuStep( AParent: TMenuItem; const AStep: string ): TMenuItem;
begin

  for var iChild := 0 to AParent.Count - 1 do
    if SameText( AParent.Items[ iChild ].Name, AStep ) then
      Exit( AParent.Items[ iChild ] );

  for var iChild := 0 to AParent.Count - 1 do
    if SameText( PlainCaption( AParent.Items[ iChild ] ), AStep ) then
      Exit( AParent.Items[ iChild ] );

  Result := nil;
  var oMatches := TJSONArray.Create;
  try
    for var iChild := 0 to AParent.Count - 1 do
    begin
      var oChild := AParent.Items[ iChild ];
      if ( not oChild.IsLine ) and PlainCaption( oChild ).ToLower.StartsWith( AStep.ToLower ) then
      begin
        Result := oChild;
        oMatches.Add( Format( '%s "%s"', [ oChild.Name, PlainCaption( oChild ) ] ) );
      end;
    end;

    if oMatches.Count = 1 then
    begin
      FreeAndNil( oMatches );
      Exit;
    end;

    if oMatches.Count > 1 then
    begin
      var oData := oMatches;
      oMatches := nil;
      raise EAutoError.CreateCodeData( 'AmbiguousMenuItem', Format( '"%s" matches %d items', [ AStep, oData.Count ] ), oData );
    end;

    for var iChild := 0 to AParent.Count - 1 do
      if not AParent.Items[ iChild ].IsLine then
        oMatches.Add( Format( '%s "%s"', [ AParent.Items[ iChild ].Name, PlainCaption( AParent.Items[ iChild ] ) ] ) );
    var oData := oMatches;
    oMatches := nil;
    raise EAutoError.CreateCodeData( 'NoMenuItem', Format( 'Nothing under "%s" is called "%s"',
      [ PlainCaption( AParent ), AStep ] ), oData );
  finally
    oMatches.Free;
  end;

end;

/// <summary>
///   Resolves a path of steps separated by <c>|</c>, from the menu bar down, filling each submenu
///   before looking inside it.
/// </summary>
/// <param name="APath">The path, e.g. <c>Tools|Options</c>.</param>
/// <param name="AChain">Receives every item on the way, the target last.</param>
/// <returns>The target item.</returns>
/// <exception cref="EAutoError"><c>BadRequest</c> for an empty path, otherwise as <see cref="FindMenuStep"/>.</exception>
function ResolveMenuPath( const APath: string; out AChain: TArray<TMenuItem> ): TMenuItem;
begin

  var aSteps := APath.Split( [ '|' ] );
  if Length( aSteps ) = 0 then
    raise EAutoError.CreateCode( 'BadRequest', 'An empty menu path' );

  Result := IdeMainMenu.Items;
  AChain := [];
  for var sStep in aSteps do
  begin
    if Trim( sStep ) = '' then
      raise EAutoError.CreateCode( 'BadRequest', 'A menu path step is empty: ' + APath );
    if Length( AChain ) > 0 then
      FillSubmenu( Result );
    Result := FindMenuStep( Result, Trim( sStep ) );
    AChain := AChain + [ Result ];
  end;

end;

/// <summary><c>ide_menu</c>: the menu bar, or the branch a path names.</summary>
/// <param name="AReq">The request: <c>path?</c> and <c>depth?</c> (default 1, at most <c>MENU_MAX_DEPTH</c>).</param>
/// <returns>Without a path <c>{ items:[...] }</c> for the menu bar; with one the item and its branch.</returns>
function CmdIdeMenu( AReq: TJSONObject ): TJSONValue;
begin

  var iDepth := OptInteger( AReq, 'depth', 1 );
  if iDepth < 0 then iDepth := 0;
  if iDepth > MENU_MAX_DEPTH then iDepth := MENU_MAX_DEPTH;

  var sPath := OptString( AReq, 'path', '' );

  if Trim( sPath ) = '' then
  begin
    var oBar := IdeMainMenu.Items;
    var oRes := TJSONObject.Create;
    var oItems := TJSONArray.Create;
    oRes.AddPair( 'items', oItems );
    for var iItem := 0 to oBar.Count - 1 do
      oItems.AddElement( MenuItemToJSON( oBar.Items[ iItem ], iDepth - 1 ) );
    Exit( oRes );
  end;

  var aChain: TArray<TMenuItem>;
  Result := MenuItemToJSON( ResolveMenuPath( sPath, aChain ), iDepth );

end;

/// <summary>
///   <c>ide_menu_click</c>: clicks a main-menu item, including the ones no action sits behind - a
///   plugin's entries, the user's tools, Reopen and Desktops. The click happens just after the
///   answer, because a command that opens a dialog would otherwise hold the answer up until
///   somebody closed it; ask <c>dialogs</c> next.
/// </summary>
/// <param name="AReq">The request: <c>path</c>.</param>
/// <returns><c>{ clickScheduled:true, item }</c>.</returns>
/// <exception cref="EAutoError">
///   <c>NotClickable</c> for a separator, a submenu, or an item that is disabled or hidden or sits in one
///   that is - <c>TMenuItem.Click</c> on those does nothing and says nothing about it (GxInspect).
/// </exception>
function CmdIdeMenuClick( AReq: TJSONObject ): TJSONValue;
begin

  var sPath := NeedString( AReq, 'path', 'ide_menu_click' );
  var aChain: TArray<TMenuItem>;
  var oItem := ResolveMenuPath( sPath, aChain );

  if oItem.IsLine then
    raise EAutoError.CreateCode( 'NotClickable', sPath + ' is a separator' );
  if oItem.Count > 0 then
    raise EAutoError.CreateCode( 'NotClickable', sPath + ' is a submenu; name an item inside it' );

  oItem.InitiateAction;
  for var oStep in aChain do
    if not ( oStep.Enabled and oStep.Visible ) then
      raise EAutoError.CreateCode( 'NotClickable', Format( '"%s" is %s', [ PlainCaption( oStep ),
        if oStep.Enabled then 'hidden' else 'disabled' ] ) );

  var sName := oItem.Name;
  DeferToMainThread(
    procedure
    begin
      //  Found again rather than captured: in the gap the IDE may have rebuilt the menu, and a
      //  freed TMenuItem must not be clicked.
      var aAgain: TArray<TMenuItem>;
      try
        var oAgain := ResolveMenuPath( sPath, aAgain );
        if oAgain.Name = sName then
          oAgain.Click;
      except
        on EAutoError do ;   // the item went away in the gap: there is nobody left to tell
      end;
    end );

  var oRes := TJSONObject.Create;
  oRes.AddPair( 'clickScheduled', TJSONBool.Create( True ) );
  oRes.AddPair( 'item', MenuItemToJSON( oItem, 0 ) );
  Result := oRes;

end;

{ ── Debugger helpers ────────────────────────────────────────────────────── }

/// <summary>
///   The process the debugger commands act on: the debugger's current one, which follows the ACTIVE
///   PROJECT. With a process stopped under one project and another made active, the process is still
///   there but no longer current, and every command here refuses (GxInspect, measured in 10.2).
/// </summary>
/// <returns>The process.</returns>
/// <exception cref="EAutoError"><c>NoProcess</c> when nothing is being debugged, or none is current.</exception>
function RequireProcess: IOTAProcess;
begin

  var oDebugger := DebuggerServices;
  Result := oDebugger.CurrentProcess;
  if Assigned( Result ) then Exit;

  if oDebugger.ProcessCount > 0 then
    raise EAutoError.CreateCode( 'NoProcess', Format( 'The active project has no process being debugged, but the IDE is ' +
      'debugging %d; the current process follows the active project, so make the one that was run active again',
      [ oDebugger.ProcessCount ] ) );
  raise EAutoError.CreateCode( 'NoProcess', 'The IDE is not debugging anything' );

end;

/// <summary>The current process, which must be stopped.</summary>
/// <returns>The process.</returns>
/// <exception cref="EAutoError"><c>NotStopped</c> when it is running.</exception>
function RequireStoppedProcess: IOTAProcess;
begin

  Result := RequireProcess;
  if Result.ProcessState not in STOPPED_STATES then
    raise EAutoError.CreateCode( 'NotStopped', Format( 'The process is %s; pause it first',
      [ EnumText( TypeInfo( TOTAProcessState ), Ord( Result.ProcessState ) ) ] ) );

end;

/// <summary>A thread of a process by its OS thread id, or the current thread when the request names none.</summary>
/// <param name="AProcess">The process.</param>
/// <param name="AReq">The request: <c>thread?</c>, an OS thread id.</param>
/// <returns>The thread.</returns>
/// <exception cref="EAutoError"><c>NoThread</c> when there is no such thread.</exception>
function ResolveThread( const AProcess: IOTAProcess; AReq: TJSONObject ): IOTAThread;
begin

  var iThreadId := OptInteger( AReq, 'thread', 0 );
  if iThreadId = 0 then
  begin
    Result := AProcess.CurrentThread;
    if Result = nil then
      raise EAutoError.CreateCode( 'NoThread', 'The process has no current thread' );
    Exit;
  end;

  for var iThread := 0 to AProcess.ThreadCount - 1 do
  begin
    Result := AProcess.Threads[ iThread ];
    if Integer( Result.OSThreadID ) = iThreadId then Exit;
  end;
  raise EAutoError.CreateCode( 'NoThread', Format( 'The process has no thread %d', [ iThreadId ] ) );

end;

/// <summary>Describes a thread: its id, state, and where it is when stopped.</summary>
/// <param name="AThread">The thread.</param>
/// <param name="ACurrent">True when it is the process's current thread.</param>
/// <returns><c>{ thread, name, state, current, file, line }</c>.</returns>
function ThreadToJSON( const AThread: IOTAThread; ACurrent: Boolean ): TJSONObject;
begin

  Result := TJSONObject.Create;
  Result.AddPair( 'thread', TJSONNumber.Create( Int64( AThread.OSThreadID ) ) );
  Result.AddPair( 'name', AThread.ThreadName );
  Result.AddPair( 'state', EnumText( TypeInfo( TOTAThreadState ), Ord( AThread.State ) ) );
  Result.AddPair( 'current', TJSONBool.Create( ACurrent ) );
  if AThread.State = tsStopped then
  begin
    Result.AddPair( 'file', AThread.CurrentFile );
    Result.AddPair( 'line', TJSONNumber.Create( Int64( AThread.CurrentLine ) ) );
  end;

end;

/// <summary>Describes the current process and, when it is stopped, where its current thread is.</summary>
/// <returns><c>{ state, pid, exe, location? }</c>, or <c>{ state:"noProcess" }</c>.</returns>
function DescribeCurrentProcess: TJSONObject;
begin

  Result := TJSONObject.Create;
  var oProcess := DebuggerServices.CurrentProcess;
  if oProcess = nil then
  begin
    Result.AddPair( 'state', 'noProcess' );
    Exit;
  end;

  Result.AddPair( 'state', EnumText( TypeInfo( TOTAProcessState ), Ord( oProcess.ProcessState ) ) );
  Result.AddPair( 'pid', TJSONNumber.Create( Int64( oProcess.OSProcessId ) ) );
  Result.AddPair( 'exe', oProcess.ExeName );
  if ( oProcess.ProcessState in STOPPED_STATES ) and Assigned( oProcess.CurrentThread ) then
    Result.AddPair( 'location', ThreadToJSON( oProcess.CurrentThread, True ) );

end;

/// <summary>
///   Sets the current process running in the given mode and, on this worker thread, waits for the
///   debugger to report the next stop. Run from a worker because the IDE processes debug events on its
///   main thread: waiting there would stop the very thing being waited for.
/// </summary>
/// <param name="AReq">The request: <c>wait?</c>, in milliseconds.</param>
/// <param name="ARunMode">How to run; ignored when <paramref name="AStart"/> is given.</param>
/// <param name="ADefaultWaitMs">The wait when the request gives none; 0 answers at once.</param>
/// <param name="AStart">
///   Called on the main thread IN PLACE OF <c>IOTAProcess.Run</c>, for a start the process interface does
///   not do properly (run to cursor); nil to run in <paramref name="ARunMode"/>.
/// </param>
/// <returns><c>{ stopped, waitedMs, state, pid?, exe?, location? }</c>; <c>stopped</c> false means the wait ran out.</returns>
/// <exception cref="EAutoError"><c>NoProcess</c> / <c>NotStopped</c>, or whatever <paramref name="AStart"/> raises.</exception>
function RunAndWait( AReq: TJSONObject; ARunMode: TOTARunMode; ADefaultWaitMs: Integer; const AStart: TProc ): TJSONValue;
begin

  var iWait := WaitArgument( AReq, ADefaultWaitMs );
  var iGeneration := 0;

  TThread.Synchronize( nil,
    procedure
    begin
      var oProcess := RequireStoppedProcess;
      iGeneration := StopGeneration;
      if Assigned( AStart ) then
        AStart
      else
        oProcess.Run( ARunMode );
    end );

  var bStopped := False;
  var rWatch := TStopwatch.StartNew;
  while rWatch.ElapsedMilliseconds < iWait do
  begin
    if StopGeneration <> iGeneration then
    begin
      bStopped := True;
      Break;
    end;
    Sleep( WAIT_POLL_MS );
  end;

  var oRes: TJSONObject := nil;
  TThread.Synchronize( nil,
    procedure
    begin
      oRes := DescribeCurrentProcess;
    end );
  oRes.AddPair( 'stopped', TJSONBool.Create( bStopped ) );
  oRes.AddPair( 'waitedMs', TJSONNumber.Create( rWatch.ElapsedMilliseconds ) );
  Result := oRes;

end;

/// <summary>
///   Finds a source file the IDE knows by a full path or by its name alone, as the request gave it.
///   A bare name is looked up among the files open in the IDE.
/// </summary>
/// <param name="AFile">The file as given.</param>
/// <returns>The full path when one is found; otherwise <paramref name="AFile"/> unchanged.</returns>
function ResolveSourceFile( const AFile: string ): string;
begin

  Result := AFile;
  if FileExists( AFile ) then Exit;

  var oServices := ModuleServices;
  for var iModule := 0 to oServices.ModuleCount - 1 do
  begin
    var oModule := oServices.Modules[ iModule ];
    for var iFile := 0 to oModule.ModuleFileCount - 1 do
    begin
      var oEditor := oModule.ModuleFileEditors[ iFile ];
      if Assigned( oEditor ) and SameText( ExtractFileName( oEditor.FileName ), ExtractFileName( AFile ) ) then
        Exit( oEditor.FileName );
    end;
  end;

end;

{ ── debug_* commands ────────────────────────────────────────────────────── }

/// <summary><c>debug_state</c>: every process the IDE is debugging, which is current, and where it stopped.</summary>
/// <param name="AReq">The request (no arguments).</param>
/// <returns><c>{ activeProject, processes:[ { pid, exe, state, current } ], current }</c>.</returns>
function CmdDebugState( AReq: TJSONObject ): TJSONValue;
begin

  var oDebugger := DebuggerServices;
  var oRes := TJSONObject.Create;
  try
    var oProject := GetActiveProject;
    if Assigned( oProject ) then
      oRes.AddPair( 'activeProject', oProject.FileName )
    else
      oRes.AddPair( 'activeProject', TJSONNull.Create );

    var oCurrent := oDebugger.CurrentProcess;
    var oProcesses := TJSONArray.Create;
    oRes.AddPair( 'processes', oProcesses );
    for var iProcess := 0 to oDebugger.ProcessCount - 1 do
    begin
      var oProcess := oDebugger.Processes[ iProcess ];
      var oItem := TJSONObject.Create;
      oProcesses.AddElement( oItem );
      oItem.AddPair( 'pid', TJSONNumber.Create( Int64( oProcess.OSProcessId ) ) );
      oItem.AddPair( 'exe', oProcess.ExeName );
      oItem.AddPair( 'state', EnumText( TypeInfo( TOTAProcessState ), Ord( oProcess.ProcessState ) ) );
      oItem.AddPair( 'current', TJSONBool.Create( Assigned( oCurrent ) and ( oCurrent.OSProcessId = oProcess.OSProcessId ) ) );
    end;

    oRes.AddPair( 'current', DescribeCurrentProcess );
    Result := oRes;
  except
    oRes.Free;
    raise;
  end;

end;

/// <summary>
///   <c>debug_attach</c>: attaches the IDE's debugger to a running process. Answered before the
///   attach has happened - ask <c>debug_state</c> whether it took. Reset in the IDE detaches rather
///   than kills the process; <c>debug_terminate</c> is what ends it.
/// </summary>
/// <param name="AReq">The request: <c>pid</c>, <c>pause?</c> (stop it the moment it is attached - what you want for something wedged).</param>
/// <returns><c>{ requested:true, pid, pause }</c>.</returns>
/// <exception cref="EAutoError">
///   <c>NoProject</c> when no project is open: the debugger takes the platform from the active project,
///   and without one the attach silently does nothing (GxInspect).
/// </exception>
function CmdDebugAttach( AReq: TJSONObject ): TJSONValue;
begin

  var iPid := NeedInteger( AReq, 'pid', 'debug_attach' );
  var bPause := OptBoolean( AReq, 'pause', False );

  if GetActiveProject = nil then
    raise EAutoError.CreateCode( 'NoProject', 'Open a project first: the debugger takes the platform to debug from it, ' +
      'and without one attaching silently does nothing' );

  DebuggerServices.AttachProcess( iPid, bPause, True );

  var oRes := TJSONObject.Create;
  oRes.AddPair( 'requested', TJSONBool.Create( True ) );
  oRes.AddPair( 'pid', TJSONNumber.Create( Int64( iPid ) ) );
  oRes.AddPair( 'pause', TJSONBool.Create( bPause ) );
  Result := oRes;

end;

/// <summary><c>debug_detach</c>: detaches from the current process, which keeps running.</summary>
/// <param name="AReq">The request (no arguments).</param>
/// <returns><c>{ detached:true, pid }</c>.</returns>
function CmdDebugDetach( AReq: TJSONObject ): TJSONValue;
begin

  var oProcess := RequireProcess;
  var iPid := oProcess.OSProcessId;
  oProcess.Detach;

  var oRes := TJSONObject.Create;
  oRes.AddPair( 'detached', TJSONBool.Create( True ) );
  oRes.AddPair( 'pid', TJSONNumber.Create( Int64( iPid ) ) );
  Result := oRes;

end;

/// <summary>
///   <c>debug_pause</c>: asks the current process to stop. Answered before it has; <c>debug_state</c>
///   confirms it. A paused process cannot answer its own automation server - talk to the IDE.
/// </summary>
/// <param name="AReq">The request (no arguments).</param>
/// <returns><c>{ requested:true, pid }</c>.</returns>
function CmdDebugPause( AReq: TJSONObject ): TJSONValue;
begin

  var oProcess := RequireProcess;
  oProcess.Pause;

  var oRes := TJSONObject.Create;
  oRes.AddPair( 'requested', TJSONBool.Create( True ) );
  oRes.AddPair( 'pid', TJSONNumber.Create( Int64( oProcess.OSProcessId ) ) );
  Result := oRes;

end;

/// <summary><c>debug_run</c>: lets a stopped process run; with <c>wait</c>, answers once it stops again (a breakpoint, say).</summary>
/// <param name="AReq">The request: <c>wait?</c> in milliseconds, default 0.</param>
/// <returns>As <see cref="RunAndWait"/>.</returns>
function CmdDebugRun( AReq: TJSONObject ): TJSONValue;
begin

  Result := RunAndWait( AReq, ormRun, 0, nil );

end;

/// <summary><c>debug_step</c>: one step, answered once the process has stopped again, saying where.</summary>
/// <param name="AReq">
///   The request: <c>mode?</c> = <c>over</c> (default), <c>into</c>, <c>out</c> (run until the function
///   returns), <c>toSource</c>, <c>instInto</c> or <c>instOver</c>; and <c>wait?</c>.
/// </param>
/// <returns>As <see cref="RunAndWait"/>.</returns>
/// <exception cref="EAutoError"><c>BadRequest</c> for an unknown mode.</exception>
function CmdDebugStep( AReq: TJSONObject ): TJSONValue;
begin

  var sMode := OptString( AReq, 'mode', 'over' );

  var eMode: TOTARunMode;
  if SameText( sMode, 'over' ) then eMode := ormStmtStepOver
  else if SameText( sMode, 'into' ) then eMode := ormStmtStepInto
  else if SameText( sMode, 'out' ) then eMode := ormRunUntilReturn
  else if SameText( sMode, 'toSource' ) then eMode := ormStmtStepToSource
  else if SameText( sMode, 'instInto' ) then eMode := ormInstStepInto
  else if SameText( sMode, 'instOver' ) then eMode := ormInstStepOver
  else
    raise EAutoError.CreateCode( 'BadRequest', 'debug_step mode is over, into, out, toSource, instInto or instOver' );

  Result := RunAndWait( AReq, eMode, STEP_WAIT_MS, nil );

end;

/// <summary>
///   <c>debug_run_to</c>: runs to a source line, the way Run to Cursor does: the file is opened, the
///   cursor placed on the line, and the editor view's own Run to Cursor invoked.
/// </summary>
/// <param name="AReq">The request: <c>file</c> (a path, or a name open in the IDE), <c>line</c>, <c>wait?</c>.</param>
/// <returns>As <see cref="RunAndWait"/>.</returns>
/// <exception cref="EAutoError">
///   <c>NoFile</c> when the IDE cannot open the file, <c>NoEditor</c> when it shows no view of it or the view
///   offers no Run to Cursor.
/// </exception>
/// <remarks>
///   NOT <c>IOTAProcess.Run( ormRunToCursor )</c>: in Delphi 13 that runs straight past the line the cursor
///   was just put on - measured here, and by GxInspect before.
/// </remarks>
function CmdDebugRunTo( AReq: TJSONObject ): TJSONValue;
begin

  var sFile := NeedString( AReq, 'file', 'debug_run_to' );
  var iLine := NeedInteger( AReq, 'line', 'debug_run_to' );

  Result := RunAndWait( AReq, ormRun, STEP_WAIT_MS,
    procedure
    begin
      var sPath := ResolveSourceFile( sFile );
      var oActions: IOTAActionServices;
      if not Supports( BorlandIDEServices, IOTAActionServices, oActions ) or not oActions.OpenFile( sPath ) then
        raise EAutoError.CreateCode( 'NoFile', 'The IDE could not open ' + sPath );

      var oEditors: IOTAEditorServices;
      if not Supports( BorlandIDEServices, IOTAEditorServices, oEditors ) or ( oEditors.TopView = nil ) or
        not SameFileName( oEditors.TopView.Buffer.FileName, sPath ) then
        raise EAutoError.CreateCode( 'NoEditor', 'The IDE shows no editor view of ' + sPath );

      var oEditActions: IOTAEditActions;
      if not Supports( oEditors.TopView, IOTAEditActions, oEditActions ) then
        raise EAutoError.CreateCode( 'NoEditor', 'The editor view of ' + sPath + ' offers no Run to Cursor' );

      var rPos: TOTAEditPos;
      rPos.Col  := 1;
      rPos.Line := iLine;
      oEditors.TopView.CursorPos := rPos;
      oEditors.TopView.MoveViewToCursor;
      oEditors.TopView.Paint;
      oEditActions.RunToCursor;
    end );

end;

/// <summary><c>debug_terminate</c>: ends the current process - the one command here that does.</summary>
/// <param name="AReq">The request (no arguments).</param>
/// <returns><c>{ terminated:true, pid }</c>.</returns>
function CmdDebugTerminate( AReq: TJSONObject ): TJSONValue;
begin

  var oProcess := RequireProcess;
  var iPid := oProcess.OSProcessId;
  oProcess.Terminate;

  var oRes := TJSONObject.Create;
  oRes.AddPair( 'terminated', TJSONBool.Create( True ) );
  oRes.AddPair( 'pid', TJSONNumber.Create( Int64( iPid ) ) );
  Result := oRes;

end;

/// <summary><c>debug_threads</c>: the current process's threads.</summary>
/// <param name="AReq">The request (no arguments).</param>
/// <returns><c>{ pid, threads:[ { thread, name, state, current, file?, line? } ] }</c>.</returns>
function CmdDebugThreads( AReq: TJSONObject ): TJSONValue;
begin

  var oProcess := RequireProcess;
  var iCurrent: LongWord := 0;
  if Assigned( oProcess.CurrentThread ) then
    iCurrent := oProcess.CurrentThread.OSThreadID;

  var oRes := TJSONObject.Create;
  oRes.AddPair( 'pid', TJSONNumber.Create( Int64( oProcess.OSProcessId ) ) );
  var oThreads := TJSONArray.Create;
  oRes.AddPair( 'threads', oThreads );
  for var iThread := 0 to oProcess.ThreadCount - 1 do
  begin
    var oThread := oProcess.Threads[ iThread ];
    oThreads.AddElement( ThreadToJSON( oThread, oThread.OSThreadID = iCurrent ) );
  end;
  Result := oRes;

end;

/// <summary><c>debug_set_thread</c>: makes a thread current, which is the one stack, registers and eval use by default.</summary>
/// <param name="AReq">The request: <c>thread</c>, an OS thread id.</param>
/// <returns>The thread as <see cref="ThreadToJSON"/> describes it.</returns>
function CmdDebugSetThread( AReq: TJSONObject ): TJSONValue;
begin

  NeedInteger( AReq, 'thread', 'debug_set_thread' );
  var oProcess := RequireProcess;
  var oThread := ResolveThread( oProcess, AReq );
  oProcess.CurrentThread := oThread;
  Result := ThreadToJSON( oThread, True );

end;

/// <summary><c>debug_stack</c>: a thread's call stack, as the Call Stack pane shows it.</summary>
/// <param name="AReq">The request: <c>thread?</c> (default the current one), <c>max?</c> frames (default 100).</param>
/// <returns><c>{ thread, count, frames:[ { index, header, file, line } ] }</c>.</returns>
/// <exception cref="EAutoError">
///   <c>StackBusy</c> when the debugger has the stack temporarily unavailable (ask again shortly);
///   <c>StackInaccessible</c> when it cannot be read at all.
/// </exception>
function CmdDebugStack( AReq: TJSONObject ): TJSONValue;
begin

  var oThread := ResolveThread( RequireStoppedProcess, AReq );
  var iMax := OptInteger( AReq, 'max', STACK_DEFAULT_MAX );
  if iMax < 1 then iMax := 1;

  case oThread.StartCallStackAccess of
    csWait:
      begin
        oThread.EndCallStackAccess;
        raise EAutoError.CreateCode( 'StackBusy', 'The call stack is temporarily unavailable; ask again shortly' );
      end;
    csInaccessible:
      begin
        oThread.EndCallStackAccess;
        raise EAutoError.CreateCode( 'StackInaccessible', 'The debugger cannot read this thread''s call stack' );
      end;
  end;

  var oRes := TJSONObject.Create;
  try
    var iCount := oThread.CallCount;
    oRes.AddPair( 'thread', TJSONNumber.Create( Int64( oThread.OSThreadID ) ) );
    oRes.AddPair( 'count', TJSONNumber.Create( iCount ) );
    var oFrames := TJSONArray.Create;
    oRes.AddPair( 'frames', oFrames );
    //  Call headers are ONE-based.
    for var iFrame := 1 to iCount do
    begin
      if iFrame > iMax then Break;
      var sFile := '';
      var iLine := 0;
      oThread.GetCallPos( iFrame, sFile, iLine );
      var oFrame := TJSONObject.Create;
      oFrames.AddElement( oFrame );
      oFrame.AddPair( 'index', TJSONNumber.Create( iFrame ) );
      oFrame.AddPair( 'header', oThread.CallHeaders[ iFrame ] );
      oFrame.AddPair( 'file', sFile );
      oFrame.AddPair( 'line', TJSONNumber.Create( iLine ) );
    end;
  finally
    oThread.EndCallStackAccess;
  end;
  Result := oRes;

end;

/// <summary>
///   Whether the debugged process is 64-bit, asked of WINDOWS. <c>IOTAProcess.GetProcessType</c> cannot
///   be trusted for this: in the 64-bit Delphi 13 IDE it answers <c>optOSX64</c> for a Win64 program
///   (GxInspect, measured).
/// </summary>
/// <param name="AProcess">The process.</param>
/// <returns>True for a 64-bit process.</returns>
/// <exception cref="EAutoError"><c>NoAccess</c> when Windows will not say.</exception>
function ProcessIs64Bit( const AProcess: IOTAProcess ): Boolean;
const
  PROCESS_QUERY_LIMITED_INFORMATION = $1000;
begin

  var hProcess := OpenProcess( PROCESS_QUERY_LIMITED_INFORMATION, False, AProcess.OSProcessId );
  if hProcess = 0 then
    raise EAutoError.CreateCode( 'NoAccess', Format( 'Process %d cannot be opened: %s',
      [ AProcess.OSProcessId, SysErrorMessage( GetLastError ) ] ) );

  var bTargetWow: BOOL := False;
  try
    if not IsWow64Process( hProcess, bTargetWow ) then
      raise EAutoError.CreateCode( 'NoAccess', 'Windows will not say whether the process is 64-bit: ' +
        SysErrorMessage( GetLastError ) );
  finally
    CloseHandle( hProcess );
  end;

{$IFDEF CPUX64}
  Result := not bTargetWow;
{$ELSE}
  var bSelfWow: BOOL := False;
  IsWow64Process( GetCurrentProcess, bSelfWow );
  Result := bSelfWow and not bTargetWow;
{$ENDIF}

end;

/// <summary>
///   Refuses a 32-bit process in the 64-bit IDE, which attaches to one but sees only the WOW64 layer:
///   a call stack in <c>wow64cpu</c>, a context that is not the 32-bit one, and no readable memory
///   (GxInspect, measured). The 32-bit IDE handles both kinds.
/// </summary>
/// <param name="AProcess">The process.</param>
/// <param name="AWhat">What was asked for, for the message.</param>
/// <returns>True when the process is 64-bit.</returns>
/// <exception cref="EAutoError"><c>Unsupported</c> for a 32-bit process in the 64-bit IDE.</exception>
function RequireReadableBitness( const AProcess: IOTAProcess; const AWhat: string ): Boolean;
begin

  Result := ProcessIs64Bit( AProcess );
{$IFDEF CPUX64}
  if not Result then
    raise EAutoError.CreateCode( 'Unsupported', Format( 'The 64-bit IDE sees only the WOW64 layer of a 32-bit process, ' +
      'so it has no %s to give; use the 32-bit IDE', [ AWhat ] ) );
{$ENDIF}

end;

/// <summary><c>debug_registers</c>: a stopped thread's general-purpose registers.</summary>
/// <param name="AReq">The request: <c>thread?</c>.</param>
/// <returns><c>{ thread, bits, registers:{ name:hex } }</c>.</returns>
/// <exception cref="EAutoError">
///   <c>Unsupported</c> for a 32-bit process in the 64-bit IDE; <c>NotStopped</c> for a thread that is not
///   stopped, which has no context the debugger could give.
/// </exception>
/// <remarks>
///   Segment and debug registers and MXCSR are deliberately left out: in the 64-bit Delphi 13 IDE the
///   context record's fields for them held rubbish - all six segment registers the low word of RAX
///   (GxInspect, measured).
/// </remarks>
function CmdDebugRegisters( AReq: TJSONObject ): TJSONValue;
begin

  var oProcess := RequireStoppedProcess;
  var oThread := ResolveThread( oProcess, AReq );
  if oThread.State <> tsStopped then
    raise EAutoError.CreateCode( 'NotStopped', Format( 'Thread %d is %s, not stopped',
      [ oThread.OSThreadID, EnumText( TypeInfo( TOTAThreadState ), Ord( oThread.State ) ) ] ) );

  var b64 := RequireReadableBitness( oProcess, 'registers' );
  var rContext := oThread.OTAThreadContextEx;

  var oRes := TJSONObject.Create;
  try
    oRes.AddPair( 'thread', TJSONNumber.Create( Int64( oThread.OSThreadID ) ) );
    var oRegs := TJSONObject.Create;
    oRes.AddPair( 'registers', oRegs );
    if b64 then
    begin
      oRes.AddPair( 'bits', TJSONNumber.Create( 64 ) );
      oRegs.AddPair( 'rax', Hex64( rContext.win64.Rax ) );
      oRegs.AddPair( 'rbx', Hex64( rContext.win64.Rbx ) );
      oRegs.AddPair( 'rcx', Hex64( rContext.win64.Rcx ) );
      oRegs.AddPair( 'rdx', Hex64( rContext.win64.Rdx ) );
      oRegs.AddPair( 'rsi', Hex64( rContext.win64.Rsi ) );
      oRegs.AddPair( 'rdi', Hex64( rContext.win64.Rdi ) );
      oRegs.AddPair( 'rbp', Hex64( rContext.win64.Rbp ) );
      oRegs.AddPair( 'rsp', Hex64( rContext.win64.Rsp ) );
      oRegs.AddPair( 'r8',  Hex64( rContext.win64.R8 ) );
      oRegs.AddPair( 'r9',  Hex64( rContext.win64.R9 ) );
      oRegs.AddPair( 'r10', Hex64( rContext.win64.R10 ) );
      oRegs.AddPair( 'r11', Hex64( rContext.win64.R11 ) );
      oRegs.AddPair( 'r12', Hex64( rContext.win64.R12 ) );
      oRegs.AddPair( 'r13', Hex64( rContext.win64.R13 ) );
      oRegs.AddPair( 'r14', Hex64( rContext.win64.R14 ) );
      oRegs.AddPair( 'r15', Hex64( rContext.win64.R15 ) );
      oRegs.AddPair( 'rip', Hex64( rContext.win64.Rip ) );
      oRegs.AddPair( 'eflags', IntToHex( rContext.win64.EFlags, 8 ) );
    end
    else
    begin
{$IFDEF CPUX86}
      oRes.AddPair( 'bits', TJSONNumber.Create( 32 ) );
      oRegs.AddPair( 'eax', IntToHex( rContext.win32.Eax, 8 ) );
      oRegs.AddPair( 'ebx', IntToHex( rContext.win32.Ebx, 8 ) );
      oRegs.AddPair( 'ecx', IntToHex( rContext.win32.Ecx, 8 ) );
      oRegs.AddPair( 'edx', IntToHex( rContext.win32.Edx, 8 ) );
      oRegs.AddPair( 'esi', IntToHex( rContext.win32.Esi, 8 ) );
      oRegs.AddPair( 'edi', IntToHex( rContext.win32.Edi, 8 ) );
      oRegs.AddPair( 'ebp', IntToHex( rContext.win32.Ebp, 8 ) );
      oRegs.AddPair( 'esp', IntToHex( rContext.win32.Esp, 8 ) );
      oRegs.AddPair( 'eip', IntToHex( rContext.win32.Eip, 8 ) );
      oRegs.AddPair( 'eflags', IntToHex( rContext.win32.EFlags, 8 ) );
{$ENDIF}
    end;
    Result := oRes;
  except
    oRes.Free;
    raise;
  end;

end;

/// <summary>Reads an address given as a number, as hex with <c>$</c> or <c>0x</c>, or as a decimal string.</summary>
/// <param name="AReq">The request.</param>
/// <returns>The address.</returns>
/// <exception cref="EAutoError"><c>BadRequest</c> when it is missing or unreadable.</exception>
function AddressArgument( AReq: TJSONObject ): UInt64;
begin

  var oValue := AReq.GetValue( 'address' );
  if oValue is TJSONNumber then
    Exit( UInt64( TJSONNumber( oValue ).AsInt64 ) );

  var sText := '';
  if oValue is TJSONString then
    sText := Trim( TJSONString( oValue ).Value );
  if sText.StartsWith( '0x', True ) then
    sText := '$' + Copy( sText, 3, MaxInt );

  var iValue: UInt64;
  if ( sText = '' ) or not TryStrToUInt64( sText, iValue ) then
    raise EAutoError.CreateCode( 'BadRequest', 'debug_memory needs "address": a number, or hex as $1234 or 0x1234' );
  Result := iValue;

end;

/// <summary>
///   <c>debug_memory</c>: bytes of the stopped process's memory, read a page at a time, so a range that
///   runs into unreadable memory still returns everything up to there and says where it stopped.
/// </summary>
/// <param name="AReq">The request: <c>address</c>, <c>count?</c> (default 64, at most 4096).</param>
/// <returns>
///   <c>{ address, requested, read, hex, stoppedAt?, reason? }</c> - <c>hex</c> is the bytes as
///   space-separated pairs; <c>stoppedAt</c> and <c>reason</c> appear when the read ended early.
/// </returns>
/// <exception cref="EAutoError">
///   <c>Unreadable</c> when not even the first byte could be read; <c>Unsupported</c> for a 32-bit process
///   in the 64-bit IDE.
/// </exception>
/// <remarks>
///   The IDE RAISES for an unreadable page rather than answering that it read nothing, and in the 64-bit
///   Delphi 13 IDE the message is "Debugger Kernel BORDBK370.DLL or BORDBK370N.DLL is missing or could not
///   be loaded" - measured here at an unmapped address. Nothing is missing; the address is not readable.
/// </remarks>
function CmdDebugMemory( AReq: TJSONObject ): TJSONValue;
const
  PAGE_BYTES = 4096;
begin

  var oProcess := RequireStoppedProcess;
  RequireReadableBitness( oProcess, 'memory' );
  var iAddress := AddressArgument( AReq );
  var iCount := OptInteger( AReq, 'count', MEMORY_DEFAULT );
  if iCount < 1 then iCount := 1;
  if iCount > MEMORY_MAX then iCount := MEMORY_MAX;

  var naBuffer: TBytes;
  SetLength( naBuffer, iCount );
  var iDone := 0;
  var sReason := '';
  while iDone < iCount do
  begin
    var iChunk := PAGE_BYTES - Integer( ( iAddress + UInt64( iDone ) ) mod PAGE_BYTES );
    if iChunk > iCount - iDone then
      iChunk := iCount - iDone;

    var iGot := 0;
    try
      iGot := oProcess.ReadProcessMemory( TOTAAddress( iAddress + UInt64( iDone ) ), iChunk, naBuffer[ iDone ] );
    except
      //  Deliberately broad: the IDE reports an unreadable page by raising, with a class of its own
      //  choosing and a misleading message (see remarks). The failure is REPORTED in the answer, not hidden.
      on E: Exception do
        sReason := Format( '%s: %s', [ E.ClassName, E.Message ] );
    end;
    if iGot <= 0 then
    begin
      if sReason = '' then sReason := 'The debugger read nothing';
      Break;
    end;
    Inc( iDone, iGot );
    if iGot < iChunk then
    begin
      sReason := 'The debugger read part of a page';
      Break;
    end;
  end;

  if iDone = 0 then
    raise EAutoError.CreateCode( 'Unreadable', Format( 'Nothing could be read at %s. The IDE said: %s ' +
      '- which it says for ANY unreadable address; nothing is missing', [ Hex64( iAddress ), sReason ] ) );

  var oBuilder := TStringBuilder.Create( iDone * 3 );
  try
    for var iByte := 0 to iDone - 1 do
    begin
      if iByte > 0 then oBuilder.Append( ' ' );
      oBuilder.Append( IntToHex( naBuffer[ iByte ], 2 ) );
    end;

    var oRes := TJSONObject.Create;
    oRes.AddPair( 'address', Hex64( iAddress ) );
    oRes.AddPair( 'requested', TJSONNumber.Create( iCount ) );
    oRes.AddPair( 'read', TJSONNumber.Create( iDone ) );
    oRes.AddPair( 'hex', oBuilder.ToString );
    if iDone < iCount then
    begin
      oRes.AddPair( 'stoppedAt', Hex64( iAddress + UInt64( iDone ) ) );
      oRes.AddPair( 'reason', sReason );
    end;
    Result := oRes;
  finally
    oBuilder.Free;
  end;

end;

/// <summary>
///   <c>debug_eval</c>: evaluates an expression the way the IDE's evaluator does - which is the
///   point: what the IDE calls a value is not what an external debugger calls it.
/// </summary>
/// <param name="AReq">The request: <c>expr</c>, <c>thread?</c>, <c>sideEffects?</c> (allow calls into the process; default false).</param>
/// <returns><c>{ expr, result, canModify, address, size }</c>.</returns>
/// <exception cref="EAutoError">
///   <c>EvalError</c> with the evaluator's message; <c>EvalDeferred</c> when it had to call into the
///   process and has no result yet; <c>EvalBusy</c> when the evaluator is busy.
/// </exception>
function CmdDebugEval( AReq: TJSONObject ): TJSONValue;
begin

  var sExpr := NeedString( AReq, 'expr', 'debug_eval' );
  var bSideEffects := OptBoolean( AReq, 'sideEffects', False );
  var oThread := ResolveThread( RequireStoppedProcess, AReq );

  var aBuffer: TArray<Char>;
  SetLength( aBuffer, EVAL_BUFFER_CHARS );
  aBuffer[ 0 ] := #0;
  var bCanModify := False;
  var iAddress: TOTAAddress := 0;
  var iSize: LongWord := 0;
  var iValue: LongWord := 0;

  var eResult := oThread.Evaluate( sExpr, PChar( aBuffer ), Length( aBuffer ), bCanModify, bSideEffects, nil,
    iAddress, iSize, iValue );
  var sText := string( PChar( aBuffer ) );

  case eResult of
    erError:    raise EAutoError.CreateCode( 'EvalError', sText );
    erDeferred: raise EAutoError.CreateCode( 'EvalDeferred', 'The evaluator had to call into the process and has no result yet' );
    erBusy:     raise EAutoError.CreateCode( 'EvalBusy', 'The evaluator is busy; ask again shortly' );
  end;

  var oRes := TJSONObject.Create;
  oRes.AddPair( 'expr', sExpr );
  oRes.AddPair( 'result', sText );
  oRes.AddPair( 'canModify', TJSONBool.Create( bCanModify ) );
  oRes.AddPair( 'address', Hex64( iAddress ) );
  oRes.AddPair( 'size', TJSONNumber.Create( Int64( iSize ) ) );
  Result := oRes;

end;

/// <summary>Describes a source breakpoint.</summary>
/// <param name="ABreakpoint">The breakpoint.</param>
/// <returns><c>{ file, line, enabled, condition, passCount }</c>.</returns>
function BreakpointToJSON( const ABreakpoint: IOTABreakpoint ): TJSONObject;
begin

  Result := TJSONObject.Create;
  Result.AddPair( 'file', ABreakpoint.FileName );
  Result.AddPair( 'line', TJSONNumber.Create( ABreakpoint.LineNumber ) );
  Result.AddPair( 'enabled', TJSONBool.Create( ABreakpoint.Enabled ) );
  Result.AddPair( 'condition', ABreakpoint.Expression );
  Result.AddPair( 'passCount', TJSONNumber.Create( ABreakpoint.PassCount ) );

end;

/// <summary>Finds a source breakpoint by file (a path, or a name alone) and line.</summary>
/// <param name="AFile">The file.</param>
/// <param name="ALine">The line.</param>
/// <returns>The breakpoint, or nil.</returns>
function FindSourceBreakpoint( const AFile: string; ALine: Integer ): IOTASourceBreakpoint;
begin

  var oDebugger := DebuggerServices;
  var bBareName := ExtractFilePath( AFile ) = '';
  for var iBreakpoint := 0 to oDebugger.SourceBkptCount - 1 do
  begin
    Result := oDebugger.SourceBkpts[ iBreakpoint ];
    if Result.LineNumber <> ALine then Continue;
    if bBareName and SameText( ExtractFileName( Result.FileName ), AFile ) then Exit;
    if ( not bBareName ) and SameFileName( Result.FileName, AFile ) then Exit;
  end;
  Result := nil;

end;

/// <summary><c>debug_breakpoints</c>: every source breakpoint.</summary>
/// <param name="AReq">The request (no arguments).</param>
/// <returns><c>{ breakpoints:[ { file, line, enabled, condition, passCount } ] }</c>.</returns>
function CmdDebugBreakpoints( AReq: TJSONObject ): TJSONValue;
begin

  var oDebugger := DebuggerServices;
  var oRes := TJSONObject.Create;
  var oList := TJSONArray.Create;
  oRes.AddPair( 'breakpoints', oList );
  for var iBreakpoint := 0 to oDebugger.SourceBkptCount - 1 do
    oList.AddElement( BreakpointToJSON( oDebugger.SourceBkpts[ iBreakpoint ] ) );
  Result := oRes;

end;

/// <summary><c>debug_breakpoint_set</c>: sets a source breakpoint, or updates the one already on that line.</summary>
/// <param name="AReq">The request: <c>file</c>, <c>line</c>, <c>condition?</c>, <c>passCount?</c>, <c>enabled?</c> (default true).</param>
/// <returns>The breakpoint as <see cref="BreakpointToJSON"/> describes it.</returns>
/// <exception cref="EAutoError"><c>BreakpointFailed</c> when the debugger declined to create it.</exception>
function CmdDebugBreakpointSet( AReq: TJSONObject ): TJSONValue;
begin

  var sFile := ResolveSourceFile( NeedString( AReq, 'file', 'debug_breakpoint_set' ) );
  var iLine := NeedInteger( AReq, 'line', 'debug_breakpoint_set' );

  var oBreakpoint: IOTABreakpoint := FindSourceBreakpoint( sFile, iLine );
  if oBreakpoint = nil then
    oBreakpoint := DebuggerServices.NewSourceBreakpoint( sFile, iLine, nil );
  if oBreakpoint = nil then
    raise EAutoError.CreateCode( 'BreakpointFailed', Format( 'The debugger set no breakpoint at %s line %d', [ sFile, iLine ] ) );

  if AReq.GetValue( 'condition' ) <> nil then
    oBreakpoint.Expression := OptString( AReq, 'condition', '' );
  if AReq.GetValue( 'passCount' ) <> nil then
    oBreakpoint.PassCount := OptInteger( AReq, 'passCount', 0 );
  oBreakpoint.Enabled := OptBoolean( AReq, 'enabled', True );

  Result := BreakpointToJSON( oBreakpoint );

end;

/// <summary><c>debug_breakpoint_delete</c>: removes the source breakpoint on a line.</summary>
/// <param name="AReq">The request: <c>file</c>, <c>line</c>.</param>
/// <returns><c>{ deleted:true, file, line }</c>.</returns>
/// <exception cref="EAutoError"><c>NoBreakpoint</c> when there is none on that line.</exception>
function CmdDebugBreakpointDelete( AReq: TJSONObject ): TJSONValue;
begin

  var sFile := NeedString( AReq, 'file', 'debug_breakpoint_delete' );
  var iLine := NeedInteger( AReq, 'line', 'debug_breakpoint_delete' );

  var oBreakpoint := FindSourceBreakpoint( sFile, iLine );
  if oBreakpoint = nil then
    raise EAutoError.CreateCode( 'NoBreakpoint', Format( 'No breakpoint at %s line %d', [ sFile, iLine ] ) );

  var sFound := oBreakpoint.FileName;
  DebuggerServices.RemoveBreakpoint( oBreakpoint );

  var oRes := TJSONObject.Create;
  oRes.AddPair( 'deleted', TJSONBool.Create( True ) );
  oRes.AddPair( 'file', sFound );
  oRes.AddPair( 'line', TJSONNumber.Create( iLine ) );
  Result := oRes;

end;

{ ── Registration ────────────────────────────────────────────────────────── }

procedure RegisterIdeCommands;
begin

  TAutomationServer.RegisterCommand( 'ide_modified', CmdIdeModified );
  TAutomationServer.RegisterCommand( 'ide_quit', CmdIdeQuit );
  TAutomationServer.RegisterCommand( 'ide_menu', CmdIdeMenu );
  TAutomationServer.RegisterCommand( 'ide_menu_click', CmdIdeMenuClick );

  TAutomationServer.RegisterCommand( 'debug_state', CmdDebugState );
  TAutomationServer.RegisterCommand( 'debug_attach', CmdDebugAttach );
  TAutomationServer.RegisterCommand( 'debug_detach', CmdDebugDetach );
  TAutomationServer.RegisterCommand( 'debug_pause', CmdDebugPause );
  TAutomationServer.RegisterCommand( 'debug_run', CmdDebugRun, actWorkerThread );
  TAutomationServer.RegisterCommand( 'debug_step', CmdDebugStep, actWorkerThread );
  TAutomationServer.RegisterCommand( 'debug_run_to', CmdDebugRunTo, actWorkerThread );
  TAutomationServer.RegisterCommand( 'debug_terminate', CmdDebugTerminate );
  TAutomationServer.RegisterCommand( 'debug_threads', CmdDebugThreads );
  TAutomationServer.RegisterCommand( 'debug_set_thread', CmdDebugSetThread );
  TAutomationServer.RegisterCommand( 'debug_stack', CmdDebugStack );
  TAutomationServer.RegisterCommand( 'debug_registers', CmdDebugRegisters );
  TAutomationServer.RegisterCommand( 'debug_memory', CmdDebugMemory );
  TAutomationServer.RegisterCommand( 'debug_eval', CmdDebugEval );
  TAutomationServer.RegisterCommand( 'debug_breakpoints', CmdDebugBreakpoints );
  TAutomationServer.RegisterCommand( 'debug_breakpoint_set', CmdDebugBreakpointSet );
  TAutomationServer.RegisterCommand( 'debug_breakpoint_delete', CmdDebugBreakpointDelete );

  var oDebugger: IOTADebuggerServices;
  if ( GNotifierIndex < 0 ) and Supports( BorlandIDEServices, IOTADebuggerServices, oDebugger ) then
    GNotifierIndex := oDebugger.AddNotifier( TStopWatcher.Create );

end;

procedure UnregisterIdeCommands;
begin

  for var sName in COMMAND_NAMES do
    TAutomationServer.UnregisterCommand( sName );

  var oDebugger: IOTADebuggerServices;
  if ( GNotifierIndex >= 0 ) and Assigned( BorlandIDEServices ) and
    Supports( BorlandIDEServices, IOTADebuggerServices, oDebugger ) then
    oDebugger.RemoveNotifier( GNotifierIndex );
  GNotifierIndex := -1;

end;

end.

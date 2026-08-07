(*
  gllIdeAutomation - in-IDE automation server

  Copyright (c) 2016-2026 Ian Branch (GITLAK Software)
  Licensed under the MIT Licence - see LICENSE at the root of this repository.

  PROVENANCE: vendored from GITLAKLib's gllAutomationServer. The body is unchanged - only this
  header, the unit name and one exception message differ - so that this package depends on the
  RTL, the VCL and Indy alone, and not on GITLAKLib. Fixes made here should be carried back to
  GITLAKLib, and vice versa; nothing keeps the two copies in step automatically.

  The unit is renamed deliberately. A Delphi unit may exist in only one loaded package, so a
  copy still called gllAutomationServer could not be loaded into an IDE that already has
  GITLAKLib installed - which is precisely the machine this was written on.

  Requires Delphi 10.3 Rio or later: the code uses inline variable declarations throughout.
*)
/// <summary>
///   In-app automation server (DEV/TEST builds only) for driving and asserting
///   on a running VCL app from an external agent (e.g. gitlak-mcp app_* tools).
///   Listens on loopback TCP, newline-delimited JSON, token-authenticated;
///   command bodies are marshalled to the main VCL thread.
///   IT MUST NOT BE STARTED IN A SHIPPED APPLICATION. Anything that can drive the UI and read
///   published properties is a debugging facility, not a product feature: reference it under
///   your own conditional and start it only on an explicit opt-in, so a release build leaves it
///   unreferenced and it can never run in front of a customer. In this package that opt-in is
///   the GITLAK_IDE_AUTOMATION environment variable - see gllIdeAutomation.Starter.
///   M-A: ping / info + discovery + token.
///   M-B: tree (forms / components) · get / set (published props) · click
///   (fire OnClick directly, or mode=message: post BM_CLICK so the reply
///   returns BEFORE a modal-opening handler runs) · action (fire a named
///   TAction's Execute). Forms addressed by name / 'main' / 'active'; components by
///   owned name; failures return a stable error code (NoForm/NoComp/NoProp/…).
///   M-D: dialogs (list / click modal-dialog buttons — runs OFF the VCL thread
///   so it still works while a modal loop blocks Synchronize) · field_get ·
///   field_set (write a field — reaches values that data-aware controls hide,
///   e.g. the LMD DB edits publish no Text) · dataset_op (insert/append/edit/
///   post/cancel/refresh/navigate — reaches what TwwNavButton does in the
///   navigator rather than in OnClick) · dataset (assert on TDataSet state).
///   M-E: screenshot (PNG of the monitor the active form/dialog is on — also
///   OFF the VCL thread, so it can capture a blocking dialog; saved to Desktop).
/// </summary>
unit gllIdeAutomation.Server;

{$IF CompilerVersion < 33.0}
  {$MESSAGE FATAL 'gllIdeAutomation requires Delphi 10.3 Rio or later (the code uses inline variables).'}
{$IFEND}

interface

type
  /// <summary>
  ///   Static facade controlling the singleton automation server. Call
  ///   <c>Start</c> once at app startup (after Application.Initialize) when the
  ///   /AUTOMATION switch is present.
  /// </summary>
  TAutomationServer = class
  public
    /// <summary>Starts the loopback automation server (idempotent).</summary>
    class procedure Start( const AAppName: string );
    /// <summary>Stops and frees the server (idempotent).</summary>
    class procedure Stop;
    /// <summary>True while the server is running.</summary>
    class function IsRunning: Boolean;
    /// <summary>The bound loopback port (0 if not running).</summary>
    class function Port: Word;
  end;

implementation

uses
  System.SysUtils, System.Classes, System.JSON, System.IOUtils, System.DateUtils,
  System.TypInfo, System.Variants, System.Generics.Collections,
  Winapi.Windows, Winapi.Messages, Winapi.MultiMon,
  Data.DB,
  Vcl.Forms, Vcl.Graphics, Vcl.Imaging.pngimage, Vcl.StdCtrls,
  IdTCPServer, IdContext, IdGlobal;

const
  /// <summary>First loopback port tried when binding the listener; the constructor scans upward from here.</summary>
  AUTOMATION_PORT_BASE = 8730;   // loopback port scan base
  /// <summary>Number of consecutive ports probed from <c>AUTOMATION_PORT_BASE</c> before the bind attempt is abandoned.</summary>
  AUTOMATION_PORT_SPAN = 200;    // ports to try before giving up
  /// <summary>Wire-protocol/feature version reported by the <c>ping</c>/<c>info</c> command's <c>server</c> field; bump when commands change.</summary>
  SERVER_VERSION       = '0.7';  // + click mode=message (async BM_CLICK) · hung-window-safe dialog text reads
  // Fixed, account-independent discovery dir so the agent (which may resolve a
  // different %TEMP%, e.g. a service) and the app always agree. The MCP side
  // can override via settings.ini [Automation] DiscoveryDir.
  /// <summary>Fixed directory holding per-PID discovery files so an external agent and the app always agree on it regardless of account or %TEMP%.</summary>
  DISCOVERY_DIR        = 'C:\ProgramData\GITLAK\Automation';

type
  /// <summary>
  ///   Concrete automation server (one per process). Owns the Indy TCP listener,
  ///   the per-session token and the discovery file, and dispatches each request
  ///   line to the correct thread — Win32-only commands (<c>dialogs</c>,
  ///   <c>screenshot</c>) on the worker thread; everything else marshalled to the
  ///   main VCL thread. Created and freed through the <see cref="TAutomationServer"/> facade.
  /// </summary>
  TServerImpl = class
  private
    /// <summary>The loopback Indy TCP listener.</summary>
    FServer        : TIdTCPServer;
    /// <summary>Application name reported by <c>ping</c>/<c>info</c> and written to the discovery file.</summary>
    FAppName       : string;
    /// <summary>Per-session GUID token that every request must carry.</summary>
    FToken         : string;
    /// <summary>The bound loopback port.</summary>
    FPort          : Word;
    /// <summary>Full path of this process's discovery file.</summary>
    FDiscoveryPath : string;
    /// <summary>Indy <c>OnExecute</c> handler: reads one request line, writes the response (worker thread).</summary>
    /// <param name="AContext">The Indy connection context.</param>
    procedure DoExecute( AContext: TIdContext );
    /// <summary>Parses + token-authenticates one request line and routes it to the correct thread (worker thread).</summary>
    /// <param name="ALine">The raw newline-delimited JSON request.</param>
    /// <returns>The JSON response line.</returns>
    function  HandleLine( const ALine: string ): string;
    /// <summary>Dispatches one parsed command and builds its JSON response (runs on the main VCL thread for VCL commands).</summary>
    /// <param name="AReq">The parsed request object.</param>
    /// <returns>A new response object the caller frees: <c>{ id, ok, result | error }</c>.</returns>
    function  ExecuteCommand( AReq: TJSONObject ): TJSONObject;
    /// <summary>Writes the per-PID discovery file (<c>app / pid / port / token / started</c>) into <c>DISCOVERY_DIR</c>.</summary>
    procedure WriteDiscovery;
    /// <summary>Deletes this process's discovery file (best-effort, swallows errors).</summary>
    procedure DeleteDiscovery;
  public
    /// <summary>Creates the server, scans for a free loopback port from <c>AUTOMATION_PORT_BASE</c>, binds it, and writes the discovery file.</summary>
    /// <param name="AAppName">The application name to advertise.</param>
    constructor Create( const AAppName: string );
    /// <summary>Stops the listener and removes the discovery file.</summary>
    destructor Destroy; override;
    /// <summary>The bound loopback port (0 before binding).</summary>
    property Port: Word read FPort;
  end;

var
  /// <summary>The process-wide automation-server singleton (<c>nil</c> when stopped).</summary>
  GImpl: TServerImpl = nil;

{ ── Helpers ─────────────────────────────────────────────────────────────── }

/// <summary>Reads the running executable's file version from its version resource.</summary>
/// <returns><c>major.minor.release.build</c> (e.g. <c>4.0.0.13</c>), or '' when no version info is present.</returns>
function GetExeFileVersion: string;
var
  iHandle : DWORD;
  iSize   : DWORD;
  naBuf   : TBytes;
  pFixed  : PVSFixedFileInfo;
  iLen    : UINT;
begin

  Result := '';

  var sExe := ParamStr( 0 );
  iSize := GetFileVersionInfoSize( PChar( sExe ), iHandle );
  if iSize = 0 then Exit;

  SetLength( naBuf, iSize );
  if ( not GetFileVersionInfo( PChar( sExe ), iHandle, iSize, naBuf ) ) then Exit;

  if VerQueryValue( naBuf, '\', Pointer( pFixed ), iLen ) and ( iLen >= SizeOf( TVSFixedFileInfo ) ) then
    Result := Format( '%d.%d.%d.%d', [ HiWord( pFixed.dwFileVersionMS ), LoWord( pFixed.dwFileVersionMS ),
      HiWord( pFixed.dwFileVersionLS ), LoWord( pFixed.dwFileVersionLS ) ] );

end;

/// <summary>Builds a minimal error-response JSON line, used before a request <c>id</c> is known.</summary>
/// <param name="ACode">Stable machine-readable error code.</param>
/// <param name="AMessage">Human-readable message (embedded double quotes are replaced with single quotes).</param>
/// <returns>A one-line JSON object: <c>{"ok":false,"error":{"code":…,"message":…}}</c>.</returns>
function ErrorJSON( const ACode, AMessage: string ): string;
begin

  Result := Format( '{"ok":false,"error":{"code":"%s","message":"%s"}}',
    [ ACode, StringReplace( AMessage, '"', '''', [ rfReplaceAll ] ) ] );

end;

{ ── TServerImpl ─────────────────────────────────────────────────────────── }

constructor TServerImpl.Create( const AAppName: string );
begin

  inherited Create;

  FAppName := AAppName;
  FToken   := TGuid.NewGuid.ToString;
  FPort    := 0;

  FServer := TIdTCPServer.Create( nil );
  FServer.OnExecute := DoExecute;

  // Scan for a free loopback port (Port=0 isn't reliably reflected back by Indy).
  for var iTry := 0 to AUTOMATION_PORT_SPAN - 1 do
  begin

    try
      FServer.Active := False;
      FServer.Bindings.Clear;
      var bnd := FServer.Bindings.Add;
      bnd.IP   := '127.0.0.1';
      bnd.Port := AUTOMATION_PORT_BASE + iTry;
      FServer.Active := True;
      FPort := AUTOMATION_PORT_BASE + iTry;
      Break;
    except
      // Port in use — try the next.
    end;
  end;

  if FPort = 0 then
    raise Exception.Create( 'gllIdeAutomation: no free loopback port in range' );

  WriteDiscovery;

end;

destructor TServerImpl.Destroy;
begin

  DeleteDiscovery;

  if Assigned( FServer ) then
  begin
    // Deactivate Indy on a helper thread while pumping CheckSynchronize here.
    // A connection thread may be blocked in TThread.Synchronize (HandleLine
    // marshals VCL commands to the main thread); FServer.Active := False waits
    // for that thread to terminate, so calling it directly on the main thread
    // would deadlock — the worker waits for the main thread to service its
    // Synchronize while the main thread waits for the worker to finish. Pumping
    // CheckSynchronize lets the worker drain and terminate. (Stop/finalisation
    // both run on the main thread.)
    if FServer.Active then
    begin
      var LFinished := False;
      var LStopper := TThread.CreateAnonymousThread(
        procedure
        begin
          try
            FServer.Active := False;
          except
          end;
          LFinished := True;
        end );
      LStopper.FreeOnTerminate := False;
      LStopper.Start;
      try
        while not LFinished do
          CheckSynchronize( 50 );
        LStopper.WaitFor;
      finally
        LStopper.Free;
      end;
    end;
    FServer.Free;
  end;

  inherited;

end;

procedure TServerImpl.WriteDiscovery;
begin

  var sDir := DISCOVERY_DIR;
  TDirectory.CreateDirectory( sDir );

  FDiscoveryPath := TPath.Combine( sDir, Format( '%d.json', [ GetCurrentProcessId ] ) );

  var o := TJSONObject.Create;
  try
    o.AddPair( 'app', FAppName );
    o.AddPair( 'pid', TJSONNumber.Create( GetCurrentProcessId ) );
    o.AddPair( 'port', TJSONNumber.Create( FPort ) );
    o.AddPair( 'token', FToken );
    o.AddPair( 'started', DateToISO8601( Now, False ) );  // Now is local; AInputIsUTC defaults True and would stamp a false 'Z'
    TFile.WriteAllText( FDiscoveryPath, o.ToJSON, TEncoding.UTF8 );
  finally
    o.Free;
  end;

end;

procedure TServerImpl.DeleteDiscovery;
begin

  if ( FDiscoveryPath <> '' ) and TFile.Exists( FDiscoveryPath ) then
    try
      TFile.Delete( FDiscoveryPath );
    except
    end;

end;

procedure TServerImpl.DoExecute( AContext: TIdContext );
begin

  var sLine := AContext.Connection.IOHandler.ReadLn( IndyTextEncoding_UTF8 );
  if sLine = '' then Exit;

  var sResp := HandleLine( sLine );
  AContext.Connection.IOHandler.WriteLn( sResp, IndyTextEncoding_UTF8 );

end;

/// <summary>
///   Keeps a driven app alive: disables any inactivity idle-timer on every open
///   form so it can't auto-close mid-test. Matched by class name (<c>*IdleTimer*</c>,
///   e.g. <c>TZylIdleTimer</c>) via RTTI, so this unit needs no dependency on the
///   timer's unit. Idempotent; called on the main thread before each VCL command,
///   so it catches the login form's timer and the MainForm's once it exists — no
///   per-app MainForm change needed. Only ever runs under <c>/AUTOMATION</c>.
/// </summary>
procedure DisableIdleTimers;
begin

  for var iFrm := 0 to Screen.FormCount - 1 do
  begin
    var oForm := Screen.Forms[ iFrm ];
    for var iC := 0 to oForm.ComponentCount - 1 do
    begin
      var oComp := oForm.Components[ iC ];
      if ( Pos( 'IDLETIMER', UpperCase( oComp.ClassName ) ) > 0 ) and IsPublishedProp( oComp, 'Enabled' ) then
        SetPropValue( oComp, 'Enabled', False );
    end;
  end;

end;

function TServerImpl.HandleLine( const ALine: string ): string;
begin

  // Parse defensively: valid-JSON-but-not-an-object input (array/number/string)
  // makes `as TJSONObject` raise EInvalidCast AND leak the parsed value. Test the
  // type instead and free the non-object value on the reject path.
  var oVal := TJSONObject.ParseJSONValue( ALine );
  if not ( oVal is TJSONObject ) then
  begin
    oVal.Free;   // no-op if nil; frees a non-object JSON value otherwise
    Exit( ErrorJSON( 'BadRequest', 'invalid JSON' ) );
  end;

  var oReq := TJSONObject( oVal );
  try
    if oReq.GetValue<string>( 'token', '' ) <> FToken then
      Exit( ErrorJSON( 'Unauthorised', 'bad or missing token' ) );

    var sResp := '';

    // 'dialogs' and 'screenshot' are Win32/GDI-only and MUST run on this
    // (background) thread: the main thread may be blocked inside a modal dialog
    // loop that never pumps CheckSynchronize, which would deadlock
    // TThread.Synchronize (and we still want to see/answer that dialog). Every
    // other command touches the VCL and is marshalled to the main thread.
    var sPeekCmd := oReq.GetValue<string>( 'cmd', '' );
    if SameText( sPeekCmd, 'dialogs' ) or SameText( sPeekCmd, 'screenshot' ) then
    begin
      var oResp := ExecuteCommand( oReq );
      try
        sResp := oResp.ToJSON;
      finally
        oResp.Free;
      end;
    end
    else
      TThread.Synchronize( nil,
        procedure
        begin
          DisableIdleTimers;            // keep the app alive while an agent drives it
          var oResp := ExecuteCommand( oReq );
          try
            sResp := oResp.ToJSON;
          finally
            oResp.Free;
          end;
        end );

    Result := sResp;
  finally
    oReq.Free;
  end;

end;

{ ── Phase-2 drive / introspect helpers ──────────────────────────────────── }

type
  /// <summary>Command-level failure carrying a stable machine-readable code.</summary>
  EAutoError = class( Exception )
  public
    /// <summary>Stable error code surfaced in the response's <c>error.code</c> (e.g. <c>NoForm</c>, <c>NoProp</c>).</summary>
    Code: string;
    /// <summary>Creates the error with a machine code and a human message.</summary>
    /// <param name="ACode">The stable error code.</param>
    /// <param name="AMsg">The human-readable message.</param>
    constructor CreateCode( const ACode, AMsg: string );
  end;

constructor EAutoError.CreateCode( const ACode, AMsg: string );
begin

  inherited Create( AMsg );
  Code := ACode;

end;

/// <summary>
///   Resolves the target form from the request's optional <c>"form"</c> key:
///   '' / 'main' → <c>Application.MainForm</c>; 'active' → <c>Screen.ActiveForm</c>;
///   otherwise the open form whose <c>Name</c> matches.
/// </summary>
/// <param name="AReq">The request object.</param>
/// <returns>The resolved form.</returns>
/// <remarks>Raises <c>EAutoError</c> —Code <c>NoForm</c> when no matching form exists.</remarks>
function AutoResolveForm( AReq: TJSONObject ): TForm;
begin

  var sForm := AReq.GetValue<string>( 'form', '' );

  if ( sForm = '' ) or SameText( sForm, 'main' ) then
  begin
    Result := Application.MainForm;
    if Result = nil then
      raise EAutoError.CreateCode( 'NoForm', 'no main form yet (the app may still be at login)' );
    Exit;
  end;

  if SameText( sForm, 'active' ) then
  begin
    Result := Screen.ActiveForm;
    if Result = nil then
      raise EAutoError.CreateCode( 'NoForm', 'no active form' );
    Exit;
  end;

  for var i := 0 to Screen.FormCount - 1 do
    if SameText( Screen.Forms[ i ].Name, sForm ) then
      Exit( Screen.Forms[ i ] );

  raise EAutoError.CreateCode( 'NoForm', 'form not found: ' + sForm );

end;

/// <summary>Resolves a component by the request's <c>"name"</c> key (owned by <paramref name="AForm"/>); an empty name targets the form itself.</summary>
/// <param name="AReq">The request object.</param>
/// <param name="AForm">The form whose owned component to find.</param>
/// <returns>The named component, or <paramref name="AForm"/> when no name is supplied.</returns>
/// <remarks>Raises <c>EAutoError</c> —Code <c>NoComp</c> when the named component is absent.</remarks>
function AutoResolveComp( AReq: TJSONObject; AForm: TForm ): TComponent;
begin

  var sName := AReq.GetValue<string>( 'name', '' );
  if sName = '' then Exit( AForm );

  Result := AForm.FindComponent( sName );
  if Result = nil then
    raise EAutoError.CreateCode( 'NoComp', Format( 'component "%s" not found on %s', [ sName, AForm.Name ] ) );

end;

/// <summary>Converts a Variant to a JSON value, typed where the variant carries enough information (bool / number / string / null).</summary>
/// <param name="V">The source value.</param>
/// <returns>A new <c>TJSONValue</c>.</returns>
function VarToJSON( const V: Variant ): TJSONValue;
begin

  case VarType( V ) and varTypeMask of
    varEmpty, varNull:
      Result := TJSONNull.Create;
    varBoolean:
      Result := TJSONBool.Create( V );
    varShortInt, varByte, varWord, varSmallint, varInteger, varLongWord, varInt64, varUInt64:
      Result := TJSONNumber.Create( Int64( V ) );
    varSingle, varDouble, varCurrency:
      Result := TJSONNumber.Create( Double( V ) );
  else
    Result := TJSONString.Create( VarToStr( V ) );
  end;

end;

/// <summary>Converts a JSON value to a Variant suitable for <c>SetPropValue</c> (which then coerces it to the property type).</summary>
/// <param name="V">The source JSON value (may be nil).</param>
/// <returns>The Variant: Null / Boolean / Int64 / Double / string.</returns>
function JSONToVar( V: TJSONValue ): Variant;
begin

  if ( V = nil ) or ( V is TJSONNull ) then
    Result := Null
  else if V is TJSONBool then
    Result := TJSONBool( V ).AsBoolean
  else if V is TJSONNumber then
  begin
    var d := TJSONNumber( V ).AsDouble;
    if Frac( d ) = 0 then Result := Int64( Trunc( d ) ) else Result := d;
  end
  else
    Result := V.Value;

end;

/// <summary>Builds a compact JSON description of one component: name, class, and the safe subset of published props it actually exposes.</summary>
/// <param name="AComp">The component to describe.</param>
/// <returns>A new <c>{ name, class, props }</c> object.</returns>
function CompToJSON( AComp: TComponent ): TJSONObject;
const
  PROPS: array[ 0 .. 9 ] of string =
    ( 'Caption', 'Text', 'Visible', 'Enabled', 'Checked', 'ItemIndex',
      'Left', 'Top', 'Width', 'Height' );
begin

  Result := TJSONObject.Create;
  Result.AddPair( 'name', AComp.Name );
  Result.AddPair( 'class', AComp.ClassName );

  var oProps := TJSONObject.Create;
  for var sP in PROPS do
    if IsPublishedProp( AComp, sP ) then
      oProps.AddPair( sP, VarToJSON( GetPropValue( AComp, sP ) ) );
  Result.AddPair( 'props', oProps );

end;

{ ── Phase-2 commands ────────────────────────────────────────────────────── }

/// <summary><c>tree</c> command: with no <c>"form"</c> key, a shallow list of all open forms; with a <c>"form"</c>, that form's owned components (one level) with their key props.</summary>
/// <param name="AReq">The request object.</param>
/// <returns><c>{ forms:[…] }</c> or <c>{ form, class, components:[…] }</c>.</returns>
function AutoCmdTree( AReq: TJSONObject ): TJSONValue;
begin

  if AReq.GetValue<string>( 'form', '' ) = '' then
  begin
    var oForms := TJSONArray.Create;
    for var i := 0 to Screen.FormCount - 1 do
    begin
      var oFrm := TJSONObject.Create;
      oFrm.AddPair( 'name', Screen.Forms[ i ].Name );
      oFrm.AddPair( 'class', Screen.Forms[ i ].ClassName );
      oFrm.AddPair( 'visible', TJSONBool.Create( Screen.Forms[ i ].Visible ) );
      oForms.AddElement( oFrm );
    end;
    Result := TJSONObject.Create;
    TJSONObject( Result ).AddPair( 'forms', oForms );
    Exit;
  end;

  var oForm := AutoResolveForm( AReq );
  var oComps := TJSONArray.Create;
  for var i := 0 to oForm.ComponentCount - 1 do
    oComps.AddElement( CompToJSON( oForm.Components[ i ] ) );

  Result := TJSONObject.Create;
  TJSONObject( Result ).AddPair( 'form', oForm.Name );
  TJSONObject( Result ).AddPair( 'class', oForm.ClassName );
  TJSONObject( Result ).AddPair( 'components', oComps );

end;

/// <summary><c>get</c> command: reads one published property of a component (or the form).</summary>
/// <param name="AReq">The request object (<c>form?</c>, <c>name?</c>, <c>prop</c>).</param>
/// <returns><c>{ name, prop, value }</c>.</returns>
/// <remarks>Raises <c>EAutoError</c> —Code <c>NoProp</c> when the property isn't published.</remarks>
function AutoCmdGet( AReq: TJSONObject ): TJSONValue;
begin

  var oForm := AutoResolveForm( AReq );
  var oComp := AutoResolveComp( AReq, oForm );
  var sProp := AReq.GetValue<string>( 'prop', '' );

  if not IsPublishedProp( oComp, sProp ) then
    raise EAutoError.CreateCode( 'NoProp', Format( '%s has no published property "%s"', [ oComp.Name, sProp ] ) );

  Result := TJSONObject.Create;
  TJSONObject( Result ).AddPair( 'name', oComp.Name );
  TJSONObject( Result ).AddPair( 'prop', sProp );
  TJSONObject( Result ).AddPair( 'value', VarToJSON( GetPropValue( oComp, sProp ) ) );

end;

/// <summary><c>set</c> command: writes one published property (variant-coerced), then reads it back.</summary>
/// <param name="AReq">The request object (<c>form?</c>, <c>name?</c>, <c>prop</c>, <c>value</c>).</param>
/// <returns><c>{ name, prop, value }</c> with the read-back value.</returns>
/// <remarks>Raises <c>EAutoError</c> —Code <c>NoProp</c> when the property isn't published.</remarks>
function AutoCmdSet( AReq: TJSONObject ): TJSONValue;
begin

  var oForm := AutoResolveForm( AReq );
  var oComp := AutoResolveComp( AReq, oForm );
  var sProp := AReq.GetValue<string>( 'prop', '' );

  if not IsPublishedProp( oComp, sProp ) then
    raise EAutoError.CreateCode( 'NoProp', Format( '%s has no published property "%s"', [ oComp.Name, sProp ] ) );

  SetPropValue( oComp, sProp, JSONToVar( AReq.GetValue( 'value' ) ) );

  Result := TJSONObject.Create;
  TJSONObject( Result ).AddPair( 'name', oComp.Name );
  TJSONObject( Result ).AddPair( 'prop', sProp );
  TJSONObject( Result ).AddPair( 'value', VarToJSON( GetPropValue( oComp, sProp ) ) );

end;

/// <summary>
///   <c>click</c> command: fires a component's <c>OnClick</c> handler (<c>Sender</c> = the
///   component), or with <c>"mode":"message"</c> posts <c>BM_CLICK</c> to a button-class
///   control instead — the reply is written BEFORE the message loop delivers the click, so
///   a handler that opens a modal dialog cannot block this command (answer the dialog with
///   <c>dialogs</c> afterwards). <c>BM_CLICK</c> drives the full <c>WM_LBUTTONDOWN/UP</c>
///   path, so <c>Action</c>, <c>ModalResult</c> and <c>OnClick</c> all fire as for a real
///   mouse click.
/// </summary>
/// <param name="AReq">The request object (<c>form?</c>, <c>name</c>, <c>mode?</c> — <c>direct</c> (default) / <c>message</c>).</param>
/// <returns><c>{ clicked, mode }</c>; message mode adds <c>posted:true</c> (the click has not yet run when the reply is written).</returns>
/// <remarks>
///   Raises <c>EAutoError</c> —Code <c>NoOnClick</c> / <c>NoHandler</c> (direct mode: no assigned handler);
///   <c>NotButton</c> (message mode: not a button-class windowed control, e.g. a TSpeedButton);
///   <c>NotClickable</c> (message mode: not visible+enabled — a user could not click it);
///   <c>BadMode</c> (unknown <c>mode</c> value).
/// </remarks>
function AutoCmdClick( AReq: TJSONObject ): TJSONValue;
begin

  var oForm := AutoResolveForm( AReq );
  var oComp := AutoResolveComp( AReq, oForm );
  var sMode := AReq.GetValue<string>( 'mode', 'direct' );

  if SameText( sMode, 'message' ) then
  begin
    // Async click: post BM_CLICK and let the reply go out before the message loop
    // delivers it. Only button-class window procedures implement BM_CLICK, so
    // anything else (incl. the unwindowed TSpeedButton) must use direct mode.
    if not ( oComp is TButtonControl ) then
      raise EAutoError.CreateCode( 'NotButton',
        Format( '%s (%s) cannot take mode=message: BM_CLICK is only handled by button-class controls', [ oComp.Name, oComp.ClassName ] ) );

    var oBtn := TButtonControl( oComp );
    // Faithful to a real invocation: a user cannot click a hidden or disabled button.
    if ( not oBtn.Visible ) or ( not oBtn.Enabled ) then
      raise EAutoError.CreateCode( 'NotClickable', oBtn.Name + ' is not visible+enabled' );

    if not PostMessage( oBtn.Handle, BM_CLICK, 0, 0 ) then
      RaiseLastOSError;

    Result := TJSONObject.Create;
    TJSONObject( Result ).AddPair( 'clicked', oComp.Name );
    TJSONObject( Result ).AddPair( 'mode', 'message' );
    TJSONObject( Result ).AddPair( 'posted', TJSONBool.Create( True ) );
    Exit;
  end;

  if not SameText( sMode, 'direct' ) then
    raise EAutoError.CreateCode( 'BadMode', Format( 'unknown click mode "%s" (expected direct / message)', [ sMode ] ) );

  var pInfo := GetPropInfo( oComp, 'OnClick' );
  if pInfo = nil then
    raise EAutoError.CreateCode( 'NoOnClick', oComp.Name + ' has no OnClick property' );

  var m := GetMethodProp( oComp, pInfo );
  if not Assigned( m.Code ) then
    raise EAutoError.CreateCode( 'NoHandler', oComp.Name + '.OnClick is not assigned' );

  var oEvent: TNotifyEvent;
  TMethod( oEvent ) := m;
  oEvent( oComp );

  Result := TJSONObject.Create;
  TJSONObject( Result ).AddPair( 'clicked', oComp.Name );
  TJSONObject( Result ).AddPair( 'mode', 'direct' );

end;

/// <summary>
///   <c>action</c> command: executes a <c>TBasicAction</c> named by <c>"name"</c>
///   (or the action assigned to the named control's <c>Action</c> property) by
///   calling <c>Execute</c> — the same path the VCL uses for a menu / toolbar
///   click, so it covers commands that have no clickable control. A disabled
///   action is refused (a user could not trigger it either). Direct invocation:
///   it does NOT first commit the focused edit's <c>OnExit</c> / validation.
/// </summary>
/// <param name="AReq">The request object (<c>form?</c>, <c>name</c>).</param>
/// <returns><c>{ executed, fromComponent }</c>.</returns>
/// <remarks>Raises <c>EAutoError</c> —Code <c>NoAction</c> when the target is neither a <c>TBasicAction</c> nor an action-bearing control; <c>ActionDisabled</c> when the resolved action is disabled.</remarks>
function AutoCmdAction( AReq: TJSONObject ): TJSONValue;
begin

  var oForm := AutoResolveForm( AReq );
  var oComp := AutoResolveComp( AReq, oForm );

  var oAction: TBasicAction := nil;
  if oComp is TBasicAction then
    oAction := TBasicAction( oComp )
  else if IsPublishedProp( oComp, 'Action' ) then
  begin
    var oObj := GetObjectProp( oComp, 'Action' );
    if oObj is TBasicAction then
      oAction := TBasicAction( oObj );
  end;

  if oAction = nil then
    raise EAutoError.CreateCode( 'NoAction', oComp.Name + ' is not a TAction and has no assigned Action' );

  // Faithful to a real invocation: a user cannot trigger a disabled action, so refuse it.
  if IsPublishedProp( oAction, 'Enabled' ) then
  begin
    var bEnabled: Boolean := GetPropValue( oAction, 'Enabled' );
    if not bEnabled then
      raise EAutoError.CreateCode( 'ActionDisabled', oAction.Name + ' is disabled' );
  end;

  oAction.Execute;

  Result := TJSONObject.Create;
  TJSONObject( Result ).AddPair( 'executed', oAction.Name );
  TJSONObject( Result ).AddPair( 'fromComponent', oComp.Name );

end;

{ ── M-D: dialogs (Win32, off the VCL thread) ─────────────────────────────── }

/// <summary>Returns a window's caption as a Delphi string, safely even when the window's owning thread is hung.</summary>
/// <param name="AWnd">The window handle.</param>
/// <returns>The window text; '' when empty, longer than 4096 chars, or the owning thread is hung / times out.</returns>
function WndText( AWnd: HWND ): string;
const
  // Titles and button captions are short; the dialog body text is a Static child this
  // unit never reads, so a fixed buffer is ample and avoids a hangable length query.
  MAX_TEXT = 4096;
begin

  // GetWindowText/GetWindowTextLength send WM_GETTEXT(LENGTH) to a same-process window
  // with NO timeout, so a hung UI thread would deadlock this worker thread — the exact
  // situation the off-thread dialogs command exists for. Read via SendMessageTimeout
  // (SMTO_ABORTIFHUNG) instead; a wedged window yields '' rather than a deadlock.
  SetLength( Result, MAX_TEXT );
  var iCopied: DWORD_PTR := 0;
  if SendMessageTimeout( AWnd, WM_GETTEXT, MAX_TEXT, LPARAM( PChar( Result ) ), SMTO_ABORTIFHUNG, 2000, @iCopied ) = 0 then
    Exit( '' );
  SetLength( Result, iCopied );

end;

/// <summary>Returns a window's class name (<c>GetClassName</c>) as a Delphi string.</summary>
/// <param name="AWnd">The window handle.</param>
/// <returns>The class name.</returns>
function WndClass( AWnd: HWND ): string;
begin

  SetLength( Result, 256 );
  var iLen := GetClassName( AWnd, PChar( Result ), 256 );
  SetLength( Result, iLen );

end;

/// <summary><c>EnumWindows</c> callback collecting this process's visible top-level windows into the <c>TList&lt;HWND&gt;</c> passed via <paramref name="AParam"/>.</summary>
/// <param name="AWnd">The enumerated window.</param>
/// <param name="AParam">Pointer to the target <c>TList&lt;HWND&gt;</c>.</param>
/// <returns>Always <c>True</c> to continue enumeration.</returns>
function EnumTopProc( AWnd: HWND; AParam: LPARAM ): BOOL; stdcall;
begin

  Result := True;

  var iPid: DWORD := 0;
  GetWindowThreadProcessId( AWnd, iPid );
  if ( iPid = GetCurrentProcessId ) and IsWindowVisible( AWnd ) then
    TList<HWND>( Pointer( AParam ) ).Add( AWnd );

end;

/// <summary><c>EnumChildWindows</c> callback collecting every child window into the <c>TList&lt;HWND&gt;</c> passed via <paramref name="AParam"/>.</summary>
/// <param name="AWnd">The enumerated child window.</param>
/// <param name="AParam">Pointer to the target <c>TList&lt;HWND&gt;</c>.</param>
/// <returns>Always <c>True</c> to continue enumeration.</returns>
function EnumChildProc( AWnd: HWND; AParam: LPARAM ): BOOL; stdcall;
begin

  TList<HWND>( Pointer( AParam ) ).Add( AWnd );
  Result := True;

end;

/// <summary>Builds a JSON array of a window's <i>visible</i> button-class children (text + control id + enabled).</summary>
/// <param name="ADlg">The dialog/window whose buttons to enumerate.</param>
/// <returns>A new array of <c>{ text, id, enabled }</c>; hidden buttons (styled TaskDialog templates ship many) are skipped.</returns>
function ButtonsOf( ADlg: HWND ): TJSONArray;
begin

  Result := TJSONArray.Create;

  var lst := TList<HWND>.Create;
  try
    EnumChildWindows( ADlg, @EnumChildProc, LPARAM( Pointer( lst ) ) );
    for var hb in lst do
    begin
      if Pos( 'button', LowerCase( WndClass( hb ) ) ) = 0 then Continue;
      // Styled TaskDialogs ship EVERY possible button as a hidden child — list
      // only the ones actually on screen, else a click "succeeds" on a no-op.
      if not IsWindowVisible( hb ) then Continue;
      var oB := TJSONObject.Create;
      oB.AddPair( 'text', WndText( hb ) );
      oB.AddPair( 'id', TJSONNumber.Create( GetDlgCtrlID( hb ) ) );
      oB.AddPair( 'enabled', TJSONBool.Create( IsWindowEnabled( hb ) ) );
      Result.AddElement( oB );
    end;
  finally
    lst.Free;
  end;

end;

/// <summary>
///   <c>dialogs</c> command (Win32-only, runs OFF the VCL thread). With no
///   <c>"button"</c> key it lists the open top-level windows and their visible
///   button children; with a <c>"button"</c> it clicks the first visible+enabled
///   button whose caption matches (case-insensitive, '&amp;' accelerators ignored).
///   Safe while a modal loop blocks the main thread; the click is delivered via
///   <c>SendMessageTimeout</c> (<c>SMTO_ABORTIFHUNG</c>) so a wedged UI can't deadlock the server.
/// </summary>
/// <param name="AReq">The request object (<c>button?</c>).</param>
/// <returns><c>{ windows:[…] }</c> (list) or <c>{ clicked, dialog }</c> (click).</returns>
/// <remarks>Raises <c>EAutoError</c> —Code <c>NoButton</c> when no open dialog has a matching button.</remarks>
function AutoCmdDialogs( AReq: TJSONObject ): TJSONValue;
begin

  var sButton := AReq.GetValue<string>( 'button', '' );

  var tops := TList<HWND>.Create;
  try
    EnumWindows( @EnumTopProc, LPARAM( Pointer( tops ) ) );

    if sButton = '' then
    begin
      var oArr := TJSONArray.Create;
      for var hw in tops do
      begin
        var oD := TJSONObject.Create;
        oD.AddPair( 'hwnd', TJSONNumber.Create( IntPtr( hw ) ) );
        oD.AddPair( 'class', WndClass( hw ) );
        oD.AddPair( 'caption', WndText( hw ) );
        oD.AddPair( 'owned', TJSONBool.Create( GetWindow( hw, GW_OWNER ) <> 0 ) );
        oD.AddPair( 'enabled', TJSONBool.Create( IsWindowEnabled( hw ) ) );
        oD.AddPair( 'buttons', ButtonsOf( hw ) );
        oArr.AddElement( oD );
      end;
      Result := TJSONObject.Create;
      TJSONObject( Result ).AddPair( 'windows', oArr );
      Exit;
    end;

    var sWant := Trim( StringReplace( sButton, '&', '', [ rfReplaceAll ] ) );
    for var hw in tops do
    begin
      var btns := TList<HWND>.Create;
      try
        EnumChildWindows( hw, @EnumChildProc, LPARAM( Pointer( btns ) ) );
        for var hb in btns do
        begin
          if Pos( 'button', LowerCase( WndClass( hb ) ) ) = 0 then Continue;
          // Only click a button the user could actually click (visible + enabled).
          if ( not IsWindowVisible( hb ) ) or ( not IsWindowEnabled( hb ) ) then Continue;
          if SameText( Trim( StringReplace( WndText( hb ), '&', '', [ rfReplaceAll ] ) ), sWant ) then
          begin
            // Capture captions BEFORE the click — BM_CLICK may destroy the
            // dialog (and its button) before we can read them back.
            var sBtnText := WndText( hb );
            var sDlgText := WndText( hw );

            var dwRes: DWORD_PTR := 0;
            SendMessageTimeout( hb, BM_CLICK, 0, 0, SMTO_ABORTIFHUNG, 5000, @dwRes );

            Result := TJSONObject.Create;
            TJSONObject( Result ).AddPair( 'clicked', sBtnText );
            TJSONObject( Result ).AddPair( 'dialog', sDlgText );
            Exit;
          end;
        end;
      finally
        btns.Free;
      end;
    end;

    raise EAutoError.CreateCode( 'NoButton', Format( 'no open dialog has a button matching "%s"', [ sButton ] ) );
  finally
    tops.Free;
  end;

end;

{ ── M-D: dataset assertions (VCL — main thread) ──────────────────────────── }

/// <summary>Resolves a component to its <c>TDataSet</c> — the dataset itself, or a <c>TDataSource</c>'s dataset.</summary>
/// <param name="AComp">The dataset or datasource component.</param>
/// <returns>The underlying dataset.</returns>
/// <remarks>Raises <c>EAutoError</c> —Code <c>NotDataSet</c> when the component is neither.</remarks>
function AsDataSet( AComp: TComponent ): TDataSet;
begin

  if AComp is TDataSet then Exit( TDataSet( AComp ) );
  if AComp is TDataSource then Exit( TDataSource( AComp ).DataSet );

  raise EAutoError.CreateCode( 'NotDataSet', AComp.Name + ' is not a TDataSet or TDataSource' );

end;

/// <summary><c>field_get</c> command: reads one field of a dataset's current record (typed value, field type, null flag).</summary>
/// <param name="AReq">The request object (<c>form?</c>, <c>name</c>, <c>field</c>).</param>
/// <returns><c>{ dataset, field, type, isNull, value }</c>.</returns>
/// <remarks>Raises <c>EAutoError</c> —Code <c>DataSetClosed</c> / <c>NoField</c>.</remarks>
function AutoCmdFieldGet( AReq: TJSONObject ): TJSONValue;
begin

  var oForm := AutoResolveForm( AReq );
  var oDS   := AsDataSet( AutoResolveComp( AReq, oForm ) );
  var sField := AReq.GetValue<string>( 'field', '' );

  if not oDS.Active then
    raise EAutoError.CreateCode( 'DataSetClosed', oDS.Name + ' is not open' );

  var oFld := oDS.FindField( sField );
  if oFld = nil then
    raise EAutoError.CreateCode( 'NoField', Format( '%s has no field "%s"', [ oDS.Name, sField ] ) );

  Result := TJSONObject.Create;
  TJSONObject( Result ).AddPair( 'dataset', oDS.Name );
  TJSONObject( Result ).AddPair( 'field', sField );
  TJSONObject( Result ).AddPair( 'type', GetEnumName( TypeInfo( TFieldType ), Ord( oFld.DataType ) ) );
  TJSONObject( Result ).AddPair( 'isNull', TJSONBool.Create( oFld.IsNull ) );
  if oFld.IsNull then
    TJSONObject( Result ).AddPair( 'value', TJSONNull.Create )
  else
    TJSONObject( Result ).AddPair( 'value', VarToJSON( oFld.Value ) );

end;

/// <summary><c>field_set</c> command: writes one field of a dataset's current record, promoting a browsing dataset into edit mode first.</summary>
/// <param name="AReq">The request object ( <c>form?</c>, <c>name</c>, <c>field</c>, <c>value</c> ).</param>
/// <returns><c>{ dataset, field, state, isNull, value }</c> with the read-back value.</returns>
/// <remarks>
///   Exists because data-aware controls commonly do NOT publish their text property — the LMD
///   data-aware edits (<c>TLMDDBEdit</c> and descendants such as <c>TLMDDBLabeledEdit</c>)
///   publish <c>Field</c> read-only and no <c>Text</c> — so <c>set</c> cannot reach the value at
///   all. Writing through the dataset works whatever the control class, and works for fields
///   that have no control on the form.
///   Raises <c>EAutoError</c> — Code <c>DataSetClosed</c> / <c>NoField</c> / <c>ReadOnlyField</c>.
/// </remarks>
function AutoCmdFieldSet( AReq: TJSONObject ): TJSONValue;
begin

  var oForm  := AutoResolveForm( AReq );
  var oDS    := AsDataSet( AutoResolveComp( AReq, oForm ) );
  var sField := AReq.GetValue<string>( 'field', '' );

  if not oDS.Active then
    raise EAutoError.CreateCode( 'DataSetClosed', oDS.Name + ' is not open' );

  var oFld := oDS.FindField( sField );
  if oFld = nil then
    raise EAutoError.CreateCode( 'NoField', Format( '%s has no field "%s"', [ oDS.Name, sField ] ) );

  if oFld.ReadOnly then
    raise EAutoError.CreateCode( 'ReadOnlyField', Format( '%s.%s is read-only', [ oDS.Name, sField ] ) );

  // Only dsBrowse is promoted. An existing dsEdit/dsInsert is deliberately left alone so that
  // filling a half-completed insert cannot restart or post the record underneath the caller.
  if oDS.State = dsBrowse then
    oDS.Edit;

  var oVal := AReq.GetValue( 'value' );
  if ( oVal = nil ) or ( oVal is TJSONNull ) then
    oFld.Clear
  else
    oFld.Value := JSONToVar( oVal );

  Result := TJSONObject.Create;
  var o := TJSONObject( Result );
  o.AddPair( 'dataset', oDS.Name );
  o.AddPair( 'field', sField );
  o.AddPair( 'state', GetEnumName( TypeInfo( TDataSetState ), Ord( oDS.State ) ) );
  o.AddPair( 'isNull', TJSONBool.Create( oFld.IsNull ) );
  if oFld.IsNull then
    o.AddPair( 'value', TJSONNull.Create )
  else
    o.AddPair( 'value', VarToJSON( oFld.Value ) );

end;

/// <summary><c>dataset_op</c> command: performs one dataset navigation or editing operation.</summary>
/// <param name="AReq">The request object ( <c>form?</c>, <c>name</c>, <c>op</c> ).</param>
/// <returns><c>{ dataset, op, state, recNo }</c>.</returns>
/// <remarks>
///   <c>op</c> is one of <c>insert</c>, <c>append</c>, <c>edit</c>, <c>post</c>, <c>cancel</c>,
///   <c>refresh</c>, <c>first</c>, <c>last</c>, <c>next</c>, <c>prior</c>.
///   Needed because the suite's navigator buttons (<c>TwwNavButton</c> with
///   <c>Style = nbsInsert</c>) perform the dataset action in the navigator itself, NOT in
///   <c>OnClick</c> — so <c>click</c> fires only the handler's UI half and never enters insert
///   mode. <c>TwwNavButton</c> is also not button-class, so <c>click</c>'s <c>message</c> mode
///   cannot reach it either.
///   Raises <c>EAutoError</c> — Code <c>DataSetClosed</c> / <c>BadOp</c>.
/// </remarks>
function AutoCmdDatasetOp( AReq: TJSONObject ): TJSONValue;
begin

  var oForm := AutoResolveForm( AReq );
  var oDS   := AsDataSet( AutoResolveComp( AReq, oForm ) );
  var sOp   := LowerCase( Trim( AReq.GetValue<string>( 'op', '' ) ) );

  if not oDS.Active then
    raise EAutoError.CreateCode( 'DataSetClosed', oDS.Name + ' is not open' );

  if      sOp = 'insert'  then oDS.Insert
  else if sOp = 'append'  then oDS.Append
  else if sOp = 'edit'    then oDS.Edit
  else if sOp = 'post'    then oDS.Post
  else if sOp = 'cancel'  then oDS.Cancel
  else if sOp = 'refresh' then oDS.Refresh
  else if sOp = 'first'   then oDS.First
  else if sOp = 'last'    then oDS.Last
  else if sOp = 'next'    then oDS.Next
  else if sOp = 'prior'   then oDS.Prior
  else
    raise EAutoError.CreateCode( 'BadOp', Format( '"%s" is not a recognised dataset op', [ sOp ] ) );

  Result := TJSONObject.Create;
  var o := TJSONObject( Result );
  o.AddPair( 'dataset', oDS.Name );
  o.AddPair( 'op', sOp );
  o.AddPair( 'state', GetEnumName( TypeInfo( TDataSetState ), Ord( oDS.State ) ) );
  o.AddPair( 'recNo', TJSONNumber.Create( oDS.RecNo ) );

end;

/// <summary><c>dataset</c> command: reports a dataset's state (active / record count / RecNo / BOF / EOF); with <c>"fields":true</c>, also the current record's field values.</summary>
/// <param name="AReq">The request object (<c>form?</c>, <c>name</c>, <c>fields?</c>).</param>
/// <returns><c>{ dataset, active, recordCount, recNo, bof, eof, fields? }</c>.</returns>
function AutoCmdDataset( AReq: TJSONObject ): TJSONValue;
begin

  var oForm := AutoResolveForm( AReq );
  var oDS   := AsDataSet( AutoResolveComp( AReq, oForm ) );

  Result := TJSONObject.Create;
  var o := TJSONObject( Result );
  o.AddPair( 'dataset', oDS.Name );
  o.AddPair( 'active', TJSONBool.Create( oDS.Active ) );
  if not oDS.Active then Exit;

  o.AddPair( 'recordCount', TJSONNumber.Create( oDS.RecordCount ) );
  o.AddPair( 'recNo', TJSONNumber.Create( oDS.RecNo ) );
  o.AddPair( 'bof', TJSONBool.Create( oDS.Bof ) );
  o.AddPair( 'eof', TJSONBool.Create( oDS.Eof ) );

  if AReq.GetValue<Boolean>( 'fields', False ) then
  begin
    var oFlds := TJSONObject.Create;
    for var i := 0 to oDS.FieldCount - 1 do
    begin
      var f := oDS.Fields[ i ];
      if f.IsNull then
        oFlds.AddPair( f.FieldName, TJSONNull.Create )
      else
        oFlds.AddPair( f.FieldName, VarToJSON( f.Value ) );
    end;
    o.AddPair( 'fields', oFlds );
  end;

end;

{ ── M-E: screenshot (Win32 GDI, off the VCL thread) ──────────────────────── }

/// <summary>user32 import: sets the calling thread's DPI-awareness context (for native-resolution capture). Not declared in this RTL's <c>Winapi.Windows</c>.</summary>
/// <param name="ADpiContext">The DPI-awareness context handle (e.g. <c>-4</c> = PER_MONITOR_AWARE_V2).</param>
/// <returns>The previous context (pass it back to restore).</returns>
// `delayed` is flagged W1002 (platform-specific) by the compiler; the delayed
// load is deliberate — the API is absent on older Windows and is resolved only
// when first called. This unit is Windows-only by design, so silence the noise
// locally and restore the directive immediately after the declaration.
{$WARN SYMBOL_PLATFORM OFF}
function SetThreadDpiAwarenessContext( ADpiContext: THandle ): THandle; stdcall; external 'user32.dll' delayed;
{$WARN SYMBOL_PLATFORM DEFAULT}

/// <summary>BitBlts a virtual-desktop rectangle (a monitor, a window, or the whole desktop) into a PNG file. Pure GDI — safe off the main thread; <c>GetDC(0)</c> spans the entire virtual desktop, so any monitor's coordinates capture correctly.</summary>
/// <param name="ARect">The screen rectangle in virtual-desktop coordinates.</param>
/// <param name="APath">Destination PNG path (parent directories are created).</param>
/// <returns><c>True</c> on success; <c>False</c> for an empty rectangle.</returns>
function CaptureRect( const ARect: TRect; const APath: string ): Boolean;
begin

  Result := False;

  var iW := ARect.Right - ARect.Left;
  var iH := ARect.Bottom - ARect.Top;
  if ( iW <= 0 ) or ( iH <= 0 ) then Exit;

  var hdcScreen := GetDC( 0 );
  try
    var oBmp := TBitmap.Create;
    try
      oBmp.PixelFormat := pf24bit;
      oBmp.SetSize( iW, iH );
      BitBlt( oBmp.Canvas.Handle, 0, 0, iW, iH, hdcScreen, ARect.Left, ARect.Top, SRCCOPY );

      ForceDirectories( ExtractFilePath( APath ) );

      var oPng := TPngImage.Create;
      try
        oPng.Assign( oBmp );
        oPng.SaveToFile( APath );
      finally
        oPng.Free;
      end;

      Result := True;
    finally
      oBmp.Free;
    end;
  finally
    ReleaseDC( 0, hdcScreen );
  end;

end;

/// <summary>Picks this process's most relevant window to capture: an active modal dialog (owned + enabled) if one is up, else the largest visible top-level form. The hidden <c>TApplication</c> window is ignored. Background-thread safe (pure Win32).</summary>
/// <returns>The chosen window handle, or <c>0</c> if none.</returns>
function FindAppWindow: HWND;
begin

  // Result is assigned unconditionally below (hDlg or hBest, hBest defaults to
  // 0), so no redundant pre-initialisation is needed.
  var tops := TList<HWND>.Create;
  try
    EnumWindows( @EnumTopProc, LPARAM( Pointer( tops ) ) );

    var hDlg: HWND := 0;
    var hBest: HWND := 0;
    var iBestArea := -1;

    for var hw in tops do
    begin
      if SameText( WndClass( hw ), 'TApplication' ) then Continue;   // hidden VCL app window

      if ( GetWindow( hw, GW_OWNER ) <> 0 ) and IsWindowEnabled( hw ) then
        hDlg := hw;                                                   // an active modal dialog

      var rc: TRect;
      if GetWindowRect( hw, rc ) then
      begin
        var iArea := ( rc.Right - rc.Left ) * ( rc.Bottom - rc.Top );
        if iArea > iBestArea then
        begin
          iBestArea := iArea;
          hBest := hw;
        end;
      end;
    end;

    if hDlg <> 0 then Result := hDlg else Result := hBest;
  finally
    tops.Free;
  end;

end;

/// <summary>
///   <c>screenshot</c> command (Win32/GDI, runs OFF the VCL thread). By default
///   captures the whole <b>monitor</b> the app's active window sits on (a modal
///   dialog if one is open, else the main form); <c>"area":"window"</c> captures
///   just that window's rectangle and <c>"area":"virtual"</c> the entire desktop.
///   The capture thread is set per-monitor DPI-aware so it grabs native resolution.
///   Writes a PNG to the user's Desktop.
/// </summary>
/// <param name="AReq">The request object (<c>area?</c>).</param>
/// <param name="AAppName">The app name, used in the PNG filename.</param>
/// <returns><c>{ path, width, height, area }</c>.</returns>
/// <remarks>Raises <c>EAutoError</c> —Code <c>CaptureFailed</c> on a GDI failure.</remarks>
function AutoCmdScreenshot( AReq: TJSONObject; const AAppName: string ): TJSONValue;
var
  rc: TRect;
  mi: TMonitorInfo;
begin

  // Make THIS (capture) thread per-monitor DPI-aware so GetMonitorInfo / GetDC /
  // BitBlt work in PHYSICAL pixels and capture the monitor at its native
  // resolution — even though the app's UI thread is DPI-unaware (on a 4K @150%
  // display an unaware capture is virtualised down to 2560x1440). -4 = V2.
  var hPrevDpi := SetThreadDpiAwarenessContext( THandle( -4 ) );
  try
    var sArea := LowerCase( AReq.GetValue<string>( 'area', '' ) );
    var hWin  := FindAppWindow;
    var sMode : string;

    if sArea = 'virtual' then
    begin
      rc.Left   := GetSystemMetrics( SM_XVIRTUALSCREEN );
      rc.Top    := GetSystemMetrics( SM_YVIRTUALSCREEN );
      rc.Right  := rc.Left + GetSystemMetrics( SM_CXVIRTUALSCREEN );
      rc.Bottom := rc.Top + GetSystemMetrics( SM_CYVIRTUALSCREEN );
      sMode     := 'virtual';
    end
    else if ( sArea = 'window' ) and ( hWin <> 0 ) and GetWindowRect( hWin, rc ) then
      sMode := 'window'
    else
    begin
      // Default: the monitor the app's active window is on.
      mi.cbSize := SizeOf( mi );
      if ( hWin <> 0 ) and GetMonitorInfo( MonitorFromWindow( hWin, MONITOR_DEFAULTTONEAREST ), @mi ) then
        rc := mi.rcMonitor
      else
      begin
        rc.Left := 0; rc.Top := 0;
        rc.Right := GetSystemMetrics( SM_CXSCREEN );
        rc.Bottom := GetSystemMetrics( SM_CYSCREEN );
      end;
      sMode := 'monitor';
    end;

    // Saved to the user's Desktop for easy viewing.
    var sPath := Format( '%s\Desktop\%s-%u.png', [ GetEnvironmentVariable( 'USERPROFILE' ), AAppName, GetTickCount ] );

    if not CaptureRect( rc, sPath ) then
      raise EAutoError.CreateCode( 'CaptureFailed', 'screen capture failed' );

    Result := TJSONObject.Create;
    TJSONObject( Result ).AddPair( 'path', sPath );
    TJSONObject( Result ).AddPair( 'width', TJSONNumber.Create( rc.Right - rc.Left ) );
    TJSONObject( Result ).AddPair( 'height', TJSONNumber.Create( rc.Bottom - rc.Top ) );
    TJSONObject( Result ).AddPair( 'area', sMode );
  finally
    if hPrevDpi <> 0 then SetThreadDpiAwarenessContext( hPrevDpi );
  end;

end;

function TServerImpl.ExecuteCommand( AReq: TJSONObject ): TJSONObject;
begin

  Result := TJSONObject.Create;

  var iId  := AReq.GetValue<Integer>( 'id', 0 );
  var sCmd := AReq.GetValue<string>( 'cmd', '' );
  Result.AddPair( 'id', TJSONNumber.Create( iId ) );

  try
    if SameText( sCmd, 'ping' ) or SameText( sCmd, 'info' ) then
    begin

      var oRes := TJSONObject.Create;
      oRes.AddPair( 'app', FAppName );
      oRes.AddPair( 'pid', TJSONNumber.Create( GetCurrentProcessId ) );
      oRes.AddPair( 'version', GetExeFileVersion );
      oRes.AddPair( 'exe', ParamStr( 0 ) );
      if Assigned( Application.MainForm ) then
        oRes.AddPair( 'mainForm', Application.MainForm.Name )
      else
        oRes.AddPair( 'mainForm', TJSONNull.Create );
      oRes.AddPair( 'server', SERVER_VERSION );

      Result.AddPair( 'ok', TJSONBool.Create( True ) );
      Result.AddPair( 'result', oRes );
    end
    else if SameText( sCmd, 'tree' ) then
    begin
      var oOut := AutoCmdTree( AReq );
      Result.AddPair( 'ok', TJSONBool.Create( True ) );
      Result.AddPair( 'result', oOut );
    end
    else if SameText( sCmd, 'get' ) then
    begin
      var oOut := AutoCmdGet( AReq );
      Result.AddPair( 'ok', TJSONBool.Create( True ) );
      Result.AddPair( 'result', oOut );
    end
    else if SameText( sCmd, 'set' ) then
    begin
      var oOut := AutoCmdSet( AReq );
      Result.AddPair( 'ok', TJSONBool.Create( True ) );
      Result.AddPair( 'result', oOut );
    end
    else if SameText( sCmd, 'click' ) then
    begin
      var oOut := AutoCmdClick( AReq );
      Result.AddPair( 'ok', TJSONBool.Create( True ) );
      Result.AddPair( 'result', oOut );
    end
    else if SameText( sCmd, 'action' ) then
    begin
      var oOut := AutoCmdAction( AReq );
      Result.AddPair( 'ok', TJSONBool.Create( True ) );
      Result.AddPair( 'result', oOut );
    end
    else if SameText( sCmd, 'dialogs' ) then
    begin
      var oOut := AutoCmdDialogs( AReq );
      Result.AddPair( 'ok', TJSONBool.Create( True ) );
      Result.AddPair( 'result', oOut );
    end
    else if SameText( sCmd, 'field_get' ) then
    begin
      var oOut := AutoCmdFieldGet( AReq );
      Result.AddPair( 'ok', TJSONBool.Create( True ) );
      Result.AddPair( 'result', oOut );
    end
    else if SameText( sCmd, 'field_set' ) then
    begin
      var oOut := AutoCmdFieldSet( AReq );
      Result.AddPair( 'ok', TJSONBool.Create( True ) );
      Result.AddPair( 'result', oOut );
    end
    else if SameText( sCmd, 'dataset_op' ) then
    begin
      var oOut := AutoCmdDatasetOp( AReq );
      Result.AddPair( 'ok', TJSONBool.Create( True ) );
      Result.AddPair( 'result', oOut );
    end
    else if SameText( sCmd, 'dataset' ) then
    begin
      var oOut := AutoCmdDataset( AReq );
      Result.AddPair( 'ok', TJSONBool.Create( True ) );
      Result.AddPair( 'result', oOut );
    end
    else if SameText( sCmd, 'screenshot' ) then
    begin
      var oOut := AutoCmdScreenshot( AReq, FAppName );
      Result.AddPair( 'ok', TJSONBool.Create( True ) );
      Result.AddPair( 'result', oOut );
    end
    else
    begin
      Result.AddPair( 'ok', TJSONBool.Create( False ) );
      var oErr := TJSONObject.Create;
      oErr.AddPair( 'code', 'UnknownCmd' );
      oErr.AddPair( 'message', 'Unknown command: ' + sCmd );
      Result.AddPair( 'error', oErr );
    end;
  except
    on E: EAutoError do
    begin
      var pOk := Result.RemovePair( 'ok' );
      if pOk <> nil then pOk.Free;
      Result.AddPair( 'ok', TJSONBool.Create( False ) );
      var oErr := TJSONObject.Create;
      oErr.AddPair( 'code', E.Code );
      oErr.AddPair( 'message', E.Message );
      Result.AddPair( 'error', oErr );
    end;
    on E: Exception do
    begin
      var pOk := Result.RemovePair( 'ok' );
      if pOk <> nil then pOk.Free;
      Result.AddPair( 'ok', TJSONBool.Create( False ) );
      var oErr := TJSONObject.Create;
      oErr.AddPair( 'code', 'Internal' );
      oErr.AddPair( 'message', E.Message );
      Result.AddPair( 'error', oErr );
    end;
  end;

end;

{ ── TAutomationServer (facade) ──────────────────────────────────────────── }

class procedure TAutomationServer.Start( const AAppName: string );
begin

  if Assigned( GImpl ) then Exit;

  GImpl := TServerImpl.Create( AAppName );

end;

class procedure TAutomationServer.Stop;
begin

  FreeAndNil( GImpl );

end;

class function TAutomationServer.IsRunning: Boolean;
begin

  Result := Assigned( GImpl );

end;

class function TAutomationServer.Port: Word;
begin

  if Assigned( GImpl ) then Result := GImpl.Port else Result := 0;

end;

initialization

finalization
  FreeAndNil( GImpl );

end.

///<summary>
/// Starts the automation server inside the Delphi IDE, so an external agent can drive the IDE
/// through its live VCL component model instead of synthesising keystrokes.
///
/// <para><b>Gating.</b> It starts only when the environment variable
/// <c>GITLAK_IDE_AUTOMATION</c> is set to 1, so an IDE launched without it is completely
/// unaffected. Deliberately NOT a command-line switch: <c>bds.exe</c> parses its own command
/// line and treats arguments it does not recognise as files to open.</para>
///
/// <para><b>To use it:</b> set the variable, then launch the IDE from the same shell:</para>
/// <code>
/// $env:GITLAK_IDE_AUTOMATION = '1'
/// Start-Process 'C:\Program Files (x86)\Embarcadero\Studio.0in64ds.exe'
/// </code>
/// <para>The IDE then registers itself in the discovery directory as <c>DelphiIDE</c>, and
/// tools/Start-IDE.ps1 does all of the above for you.</para>
///
/// <para><b>What it is good for:</b> driving menus, actions, dialogs and controls through the
/// live VCL component model - coordinate-free, DPI-independent, and it cannot type into the
/// wrong window. <b>What it is not:</b> a way to read the Local Variables or Watch panes
/// directly. Those are VirtualStringTree and their cell text is not a published property; see
/// tools/read_pane.py for the clipboard route round that.</para> </summary>
unit gllIdeAutomation.Starter;

{$IF CompilerVersion < 33.0}
  {$MESSAGE FATAL 'gllIdeAutomation requires Delphi 10.3 Rio or later.'}
{$IFEND}

interface

implementation

uses
  System.SysUtils,
  gllIdeAutomation.Server;

const
  ///<summary> Environment variable that must be '1' before the server is started. </summary>
  ENV_GATE = 'GITLAK_IDE_AUTOMATION';
  ///<summary> Name the IDE is discovered under, i.e. what app_list reports. </summary>
  APP_NAME = 'DelphiIDE';

///<summary>
/// @returns True if the gate environment variable is set to 1 </summary>
function AutomationRequested: Boolean;
begin
  Result := Trim( GetEnvironmentVariable( ENV_GATE ) ) = '1';
end;

initialization
  // Every failure mode here is swallowed deliberately. This package is loaded during IDE
  // startup, before any user work exists to be saved, and an exception escaping a design-time
  // package's initialisation is shown to the user as a package load failure - for a facility
  // they did not ask for and, ungated, are not even using. A port clash or a read-only
  // discovery directory must cost the automation server, never the IDE.
  try
    if ( AutomationRequested ) then
      TAutomationServer.Start( APP_NAME );
  except
    // Intentionally silent - see above.
  end;

finalization
  try
    TAutomationServer.Stop;
  except
    // Likewise: a failure while the IDE is closing must not turn into a shutdown hang.
  end;

end.

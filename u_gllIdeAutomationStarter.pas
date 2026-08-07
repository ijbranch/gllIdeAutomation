///<summary>
/// Starts the GITLAK automation server inside the Delphi IDE, so the <c>app_*</c> agent tools
/// can drive the IDE the way they already drive the DBi* applications.
///
/// The server itself is <c>gllAutomationServer</c> in GITLAKLib, which is already compiled into
/// GITLAKLib370.bpl and already loaded by the IDE - so nothing new is being introduced into the
/// process. All this unit does is call <c>Start</c>, which nobody was calling.
///
/// <para><b>Gating.</b> It starts only when the environment variable
/// <c>GITLAK_IDE_AUTOMATION</c> is set to 1, so an IDE launched normally - from the Start menu,
/// by a file association, by anything at all that does not deliberately set that variable - is
/// completely unaffected. The DBi apps gate on <c>/AUTOMATION</c> on the command line, which
/// would be wrong here: <c>bds.exe</c> parses its own command line and treats unrecognised
/// arguments as files to open.</para>
///
/// <para><b>To use it:</b> set the variable, then launch the IDE from the same shell:</para>
/// <code>
/// $env:GITLAK_IDE_AUTOMATION = '1'
/// Start-Process 'C:\Program Files (x86)\Embarcadero\Studio\37.0\bin64\bds.exe' `
///   -ArgumentList '/highdpi:unaware'
/// </code>
/// <para>The IDE then appears in <c>app_list</c> as <c>DelphiIDE</c>.</para>
///
/// <para><b>What it is good for:</b> driving menus, actions, dialogs and controls through the
/// live VCL component model, which is far more reliable than synthesising keystrokes -
/// coordinate-free, DPI-independent, and it cannot type into the wrong window. <b>What it is
/// not good for:</b> reading the Local Variables or Watch panes. Those are VirtualStringTree
/// based and their cell text is not a published property, so a screenshot is still the way to
/// read a debugger pane.</para> </summary>
unit u_gllIdeAutomationStarter;

interface

implementation

uses
  System.SysUtils,
  gllAutomationServer;

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

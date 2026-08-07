<#
.SYNOPSIS
    Launches the Delphi 13 IDE the way this machine expects it: DPI-unaware, with the automation
    gate set.

.DESCRIPTION
    Two settings that are easy to get wrong and silently wrong when you do:

    * /highdpi:unaware - Ian's standard configuration. It is a command-line switch, not a
      compatibility flag, so there is no AppCompatFlags entry to inherit and a plain launch
      quietly gives an IDE he does not work in.
    * GITLAK_IDE_AUTOMATION=1 - starts the automation server inside the IDE. Set permanently at
      user scope as well, so a Start-menu launch is drivable too; this script sets it for the
      child process regardless, so the script works even if that has been undone.

    Waits until the IDE has finished loading and reports whether the automation server came up.

.PARAMETER Project
    Optional .dproj / .groupproj to open.

.PARAMETER NoAutomation
    Launch WITHOUT the automation gate, for comparing behaviour against a clean IDE.

.EXAMPLE
    .\Start-IDE.ps1 -Project D:\glldzdebugvisualizer\test\vistest\vistest.dproj
#>
[CmdletBinding()]
param(
    [string] $Project,
    [switch] $NoAutomation
)

$bds = 'C:\Program Files (x86)\Embarcadero\Studio\37.0\bin64\bds.exe'
if ( -not ( Test-Path $bds ) ) { throw "IDE not found at $bds" }

if ( -not $NoAutomation ) { $env:GITLAK_IDE_AUTOMATION = '1' }
else { $env:GITLAK_IDE_AUTOMATION = '0' }

$argList = @( '/highdpi:unaware' )
if ( $Project ) {
    if ( -not ( Test-Path $Project ) ) { throw "Project not found: $Project" }
    $argList += "`"$Project`""
}

$before = ( Get-Process bds -ErrorAction SilentlyContinue ).Id
Start-Process -FilePath $bds -ArgumentList $argList
Write-Host "launching$( if ( $NoAutomation ) { ' (automation OFF)' } else { ' with automation' } )..."

# The IDE reports no MainWindowTitle for the first half-minute or so; poll rather than sleep.
$deadline = ( Get-Date ).AddSeconds( 120 )
do {
    Start-Sleep -Seconds 2
    $proc = Get-Process bds -ErrorAction SilentlyContinue | Where-Object { $_.Id -notin $before }
} until ( ( $proc -and $proc.MainWindowTitle ) -or ( Get-Date ) -gt $deadline )

if ( -not $proc ) { throw 'IDE process did not start' }
Write-Host "PID $($proc.Id): $($proc.MainWindowTitle)"

if ( -not $NoAutomation ) {
    $discovery = "C:\ProgramData\GITLAK\Automation\$($proc.Id).json"
    if ( Test-Path $discovery ) {
        $d = Get-Content $discovery -Raw | ConvertFrom-Json
        Write-Host "automation server: $($d.app) on port $($d.port)"
    }
    else {
        Write-Warning "No discovery file at $discovery - the automation server did not start. Is gllIdeAutomation370.bpl installed in Known Packages x64?"
    }
}

<#
.SYNOPSIS
    Launches the Delphi IDE with the automation gate set, DPI-unaware.

.DESCRIPTION
    Two settings that are easy to get wrong and silently wrong when you do:

    * /highdpi:unaware - optional, but the IDE's fonts render poorly under DPI-aware scaling on
      some displays. It is a command-line switch, not a compatibility flag, so there is no
      AppCompatFlags entry to inherit and a plain launch silently gives you the other IDE.
    * GITLAK_IDE_AUTOMATION=1 - starts the automation server inside the IDE. Set permanently at
      user scope as well, so a Start-menu launch is drivable too; this script sets it for the
      child process regardless, so the script works even if that has been undone.

    With no -BdsPath or -Version, the newest installed IDE is found from the registry
    (HKCU then HKLM, Software\Embarcadero\BDS\<ver>\RootDir), preferring the 64-bit bin64\bds.exe
    where a version ships one.

    Waits until the IDE has finished loading and reports whether the automation server came up.

.PARAMETER Project
    Optional .dproj / .groupproj to open.

.PARAMETER Version
    BDS version to launch, e.g. '37.0' for Delphi 13 or '22.0' for Delphi 11. Defaults to the
    newest installed.

.PARAMETER BdsPath
    Full path to a bds.exe, bypassing registry discovery entirely.

.PARAMETER NoAutomation
    Launch WITHOUT the automation gate, for comparing behaviour against a clean IDE.

.EXAMPLE
    .\Start-IDE.ps1

.EXAMPLE
    .\Start-IDE.ps1 -Version 22.0 -Project C:\work\thing.dproj
#>
[CmdletBinding()]
param(
    [string] $Project,
    [string] $Version,
    [string] $BdsPath,
    [switch] $NoAutomation
)

# BDS version -> the product name people actually say, and the package suffix that goes with it.
# The suffixes mirror the $LIBSUFFIX rules in gllIdeAutomation.dpk; keep the two in step.
$known = @{
    '20.0' = @{ Name = '10.3 Rio';     Suffix = '260' }
    '21.0' = @{ Name = '10.4 Sydney';  Suffix = '270' }
    '22.0' = @{ Name = '11 Alexandria'; Suffix = '280' }
    '23.0' = @{ Name = '12 Athens';    Suffix = '290' }
    '37.0' = @{ Name = '13 Florence';  Suffix = '370' }
}

function Get-InstalledIDE {
    # Both hives: a per-user install registers under HKCU only, a machine-wide one under HKLM.
    $found = @{}
    foreach ( $hive in 'HKCU:\Software\Embarcadero\BDS', 'HKLM:\Software\Embarcadero\BDS' ) {
        if ( -not ( Test-Path $hive ) ) { continue }
        foreach ( $key in Get-ChildItem $hive -ErrorAction SilentlyContinue ) {
            $ver = $key.PSChildName
            if ( $found.ContainsKey( $ver ) ) { continue }   # HKCU wins, being more specific
            $root = ( Get-ItemProperty $key.PSPath -Name RootDir -ErrorAction SilentlyContinue ).RootDir
            if ( -not $root ) { continue }
            # 12 Athens and later ship a 64-bit IDE; prefer it, since the design-time package
            # must match the IDE's bitness and bin64 is what those versions actually run.
            $exe = $null
            foreach ( $rel in 'bin64\bds.exe', 'bin\bds.exe' ) {
                $candidate = Join-Path $root $rel
                if ( Test-Path $candidate ) { $exe = $candidate; break }
            }
            if ( $exe ) { $found[ $ver ] = $exe }
        }
    }
    $found.GetEnumerator() |
        Sort-Object { try { [version] $_.Key } catch { [version] '0.0' } } -Descending
}

if ( $BdsPath ) {
    if ( -not ( Test-Path $BdsPath ) ) { throw "IDE not found at $BdsPath" }
    $bds        = $BdsPath
    $bdsVersion = $null
}
else {
    $installed = @( Get-InstalledIDE )
    if ( -not $installed ) {
        throw 'No Delphi installation found in the registry. Pass -BdsPath to point at a bds.exe directly.'
    }
    if ( $Version ) {
        $match = $installed | Where-Object { $_.Key -eq $Version }
        if ( -not $match ) {
            throw "Delphi $Version is not installed. Found: $( ( $installed | ForEach-Object { $_.Key } ) -join ', ' )"
        }
    }
    else {
        $match = $installed[ 0 ]
    }
    $bds        = $match.Value
    $bdsVersion = $match.Key
}

$label = "Delphi $bdsVersion"
if ( $bdsVersion -and $known.ContainsKey( $bdsVersion ) ) { $label = "Delphi $( $known[ $bdsVersion ].Name )" }
if ( -not $bdsVersion ) { $label = 'the IDE' }

if ( -not $NoAutomation ) { $env:GITLAK_IDE_AUTOMATION = '1' }
else { $env:GITLAK_IDE_AUTOMATION = '0' }

$argList = @( '/highdpi:unaware' )
if ( $Project ) {
    if ( -not ( Test-Path $Project ) ) { throw "Project not found: $Project" }
    $argList += "`"$Project`""
}

$before = ( Get-Process bds -ErrorAction SilentlyContinue ).Id
Start-Process -FilePath $bds -ArgumentList $argList
Write-Host "launching $label$( if ( $NoAutomation ) { ' (automation OFF)' } else { ' with automation' } )..."

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
        # Name the exact BPL and registry key where we can, since "it didn't start" is otherwise
        # a hard thing to act on. Both depend on the version and the IDE's bitness.
        $hint = 'the gllIdeAutomation package'
        if ( $bdsVersion -and $known.ContainsKey( $bdsVersion ) ) {
            $hint = "gllIdeAutomation$( $known[ $bdsVersion ].Suffix ).bpl"
        }
        if ( $bds -match '\\bin64\\' ) { $regKey = 'Known Packages x64' } else { $regKey = 'Known Packages' }
        Write-Warning "No discovery file at $discovery - the automation server did not start. Is $hint installed under $regKey, and built for the IDE's bitness?"
    }
}

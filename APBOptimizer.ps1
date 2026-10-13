<#
.NOTES
    Author         : Chris Titus @christitustech
    Runspace Author: @DeveloperDurp
    GitHub         : https://github.com/ChrisTitusTech
    Version        : 26.10.12
#>

param (
    [string]$Config,
    [ValidateSet("Standard", "Minimal", "Advanced", "")]
    [string]$Preset,
    [switch]$Offline
)

function Test-WinUtilOwnsFileProcess {
    <#
        .SYNOPSIS
            Whether the current process was launched with this script as its file target
    #>
    param(
        [string]$ScriptPath = $PSCommandPath,
        [string[]]$CommandLineArgs = [Environment]::GetCommandLineArgs()
    )

    if ([string]::IsNullOrWhiteSpace($ScriptPath)) { return $false }

    $hostOptionKinds = [ordered]@{
        Command           = "Command"
        EncodedCommand    = "Command"
        CommandWithArgs   = "Command"
        File              = "File"
        ConfigurationFile = "Value"
        ConfigurationName = "Value"
        CustomPipeName    = "Value"
        ExecutionPolicy   = "Value"
        InputFormat       = "Value"
        Interactive       = "Switch"
        Login             = "Switch"
        MTA               = "Switch"
        NoLogo            = "Switch"
        NonInteractive    = "Switch"
        NoProfile         = "Switch"
        NoProfileLoadTime = "Switch"
        OutputFormat      = "Value"
        PSConsoleFile     = "Value"
        SettingsFile      = "Value"
        SSHServerMode     = "Switch"
        STA               = "Switch"
        Version           = "Value"
        WindowStyle       = "Value"
        WorkingDirectory  = "Value"
        NoExit            = "NoExit"
    }
    $hostOptionAliases = @{
        c = "Command"; cwa = "Command"; e = "Command"; ec = "Command"; f = "File"
        noe = "NoExit"
        config = "Value"; ConfigName = "Value"; CustomPipe = "Value"; ep = "Value"; ex = "Value"
        i = "Switch"; Input = "Value"; In = "Value"; if = "Value"
        Output = "Value"; Out = "Value"; of = "Value"
        Settings = "Value"; Window = "Value"; w = "Value"; Working = "Value"; wd = "Value"
    }

    function Get-WinUtilHostOptionKind {
        param([string]$Argument)

        if ([string]::IsNullOrWhiteSpace($Argument) -or -not $Argument.StartsWith("-")) {
            return $null
        }

        $optionName = $Argument.TrimStart("-")
        if ($hostOptionAliases.ContainsKey($optionName)) {
            return $hostOptionAliases[$optionName]
        }

        # pwsh accepts any unambiguous prefix of a host option, such as -WorkingD.
        $matchingOptions = @($hostOptionKinds.Keys | Where-Object {
            $_.StartsWith($optionName, [StringComparison]::OrdinalIgnoreCase)
        })
        $matchingKinds = @($matchingOptions | ForEach-Object { $hostOptionKinds[$_] } | Select-Object -Unique)
        if ($matchingKinds.Count -eq 1) {
            return $matchingKinds[0]
        }

        return $null
    }

    :hostArguments for ($index = 1; $index -lt $CommandLineArgs.Count; $index++) {
        $optionKind = Get-WinUtilHostOptionKind -Argument $CommandLineArgs[$index]
        switch ($optionKind) {
            "Command" { return $false }
            "NoExit" { return $false }
            "Switch" { continue hostArguments }
            "File" {
                if ($index + 1 -ge $CommandLineArgs.Count) { return $false }
                $fileTarget = $CommandLineArgs[$index + 1]
                if ([string]::IsNullOrWhiteSpace($fileTarget) -or $fileTarget -eq "-") {
                    return $false
                }

                return [string]::Equals(
                    [IO.Path]::GetFullPath($fileTarget),
                    [IO.Path]::GetFullPath($ScriptPath),
                    [StringComparison]::OrdinalIgnoreCase
                )
            }
            "Value" {
                $index++
                continue hostArguments
            }
        }

        if ($CommandLineArgs[$index].StartsWith("-")) {
            continue
        }

        return [string]::Equals(
            [IO.Path]::GetFullPath($CommandLineArgs[$index]),
            [IO.Path]::GetFullPath($ScriptPath),
            [StringComparison]::OrdinalIgnoreCase
        )
    }

    return $false
}

# A headless script launched with powershell.exe/pwsh.exe -File owns its process and must set
# that process's exit code. An invoked or in-memory script must return without closing its caller.
$script:WinUtilIsFileProcess = Test-WinUtilOwnsFileProcess

$PARAM_OFFLINE = $false
if ($Offline) {
    $PARAM_OFFLINE = $true
}

if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
    Write-Host "WinUtil is unable to run on your system. PowerShell execution is restricted by security policies." -ForegroundColor Red
    $global:LASTEXITCODE = 1
    if ($env:WINUTIL_HEADLESS_CHILD -eq "1" -or $script:WinUtilIsFileProcess) { exit 1 }
    return 1
}

function New-WinUtilElevationCommand {
    <#
        .SYNOPSIS
            Encodes the relaunch target and bound parameters as data for an elevated child
    #>
    param(
        [string]$ScriptPath,
        [hashtable]$Parameters = @{},
        [switch]$Headless
    )

    $launchData = @{
        ScriptPath = $ScriptPath
        Parameters = $Parameters
        Headless = [bool]$Headless
    }
    $serializedLaunch = [System.Management.Automation.PSSerializer]::Serialize($launchData)
    $launchPayload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($serializedLaunch))

    # Only base64 is embedded in executable text. User-controlled values are deserialized and
    # splatted as parameter data in the child, so quotes in Config cannot become PowerShell code.
    $bootstrap = @"
`$launchXml = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$launchPayload'))
`$launch = [System.Management.Automation.PSSerializer]::Deserialize(`$launchXml)
`$invokeParameters = `$launch.Parameters
if (`$launch.Headless) { `$env:WINUTIL_HEADLESS_CHILD = '1' }
if (`$launch.ScriptPath) {
    & `$launch.ScriptPath @invokeParameters
} else {
    throw 'Execute the local APBOptimizer PS1 file to elevate; in-memory elevation is disabled.'
}
"@

    return [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bootstrap))
}

if (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Output "WinUtil needs to be run as Administrator. Attempting to relaunch."
    $elevationParameters = @{}
    foreach ($parameter in $PSBoundParameters.GetEnumerator()) {
        $elevationParameters[$parameter.Key] = if ($parameter.Value -is [switch]) {
            [bool]$parameter.Value
        } else {
            $parameter.Value
        }
    }

    $powershellCmd = if (Get-Command pwsh -ErrorAction SilentlyContinue) { "pwsh" } else { "powershell" }

    # A headless caller is waiting on this process for an outcome, so the elevated run has to be
    # waited on and its code handed back. A terminal tab is skipped for the same reason: the
    # exit code of wt.exe is its own, not the run's.
    if ($Config -or $Preset) {
        # A declined UAC prompt throws, which would leave $elevated null and exit 0: the caller
        # waiting on this process would read that as a successful run
        try {
            $elevationCommand = New-WinUtilElevationCommand -ScriptPath $PSCommandPath -Parameters $elevationParameters -Headless
            $elevated = Start-Process $powershellCmd -ArgumentList @("-ExecutionPolicy", "Bypass", "-NoProfile", "-EncodedCommand", $elevationCommand) -Verb RunAs -Wait -PassThru -ErrorAction Stop
        } catch {
            Write-Host "Elevation was declined or failed: $($_.Exception.Message)" -ForegroundColor Red
            $global:LASTEXITCODE = 1
            if ($script:WinUtilIsFileProcess) { exit 1 }
            return 1
        }
        $global:LASTEXITCODE = $elevated.ExitCode
        if ($script:WinUtilIsFileProcess) { exit $elevated.ExitCode }
        return $elevated.ExitCode
    }

    $processCmd = if (Get-Command wt.exe -ErrorAction SilentlyContinue) { "wt.exe" } else { "$powershellCmd" }
    $elevationCommand = New-WinUtilElevationCommand -ScriptPath $PSCommandPath -Parameters $elevationParameters

    if ($processCmd -eq "wt.exe") {
        Start-Process $processCmd -ArgumentList "$powershellCmd -ExecutionPolicy Bypass -NoProfile -EncodedCommand $elevationCommand" -Verb RunAs
    } else {
        Start-Process $processCmd -ArgumentList @("-ExecutionPolicy", "Bypass", "-NoProfile", "-EncodedCommand", $elevationCommand) -Verb RunAs
    }

    break
}

# Variable to sync between runspaces
$sync = [Hashtable]::Synchronized(@{})
$sync.version = "26.10.12"
$sync.IsLocalCompile = "true" -eq "true"
$sync.configs = @{}
$sync.Buttons = [System.Collections.Generic.List[PSObject]]::new()
$sync.preferences = @{}
# Name of the job currently running, or $null when idle. Owned by Start-WinUtilJob.
$sync.ActiveJob = $null
# Serializes worker-pool startup with recycling and shutdown.
$sync.RunspacePoolLock = [object]::new()
# Serializes the speculative and UI-thread taskbar overlay renderers.
$sync.AssetRenderLock = [object]::new()
$sync.RenderedAssetCache = [Hashtable]::Synchronized(@{})
# Every step recorded by Measure-WinUtilStep, from any thread
$sync.StepTimings = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new())
# Every error logged, so a job can report that something went wrong even when it did not throw
$sync.LoggedErrors = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new())
$sync.StartedAt = Get-Date
$sync.selectedTweaks = [System.Collections.Generic.List[string]]::new()
$sync.selectedToggles = [System.Collections.Generic.List[string]]::new()
$sync.currentTab = "Tweaks"

$dateTime = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$winutildir = "$env:LocalAppData\APBOptimizer"
$sync.winutildir = $winutildir

$logdir = "$winutildir\logs"
# Start-Transcript fails outright when the directory is missing, which is every first run
if (-not (Test-Path $logdir)) {
    New-Item -ItemType Directory -Path $logdir -Force | Out-Null
}
# Keep console output and structured entries in the path reported to the user. Write-WinUtilLog
# writes through the host while this transcript owns the file, avoiding competing file handles.
$sync.logPath = "$logdir\winutil_$dateTime.log"
$sync.transcriptPath = $sync.logPath
Start-Transcript -Path $sync.transcriptPath -Append -NoClobber | Out-Null

$Host.UI.RawUI.WindowTitle = "WinUtil"
Clear-Host
function Close-WinUtilRunspacePool {
    <#
        .SYNOPSIS
            Stops anything still running and closes the worker pool

        .DESCRIPTION
            Closing the pool with work still in it is what produced an unhandled
            InvalidRunspaceStateException: a queued instance starts on a runspace that is already
            closing, throws on a thread pool thread, and takes the process down. Whatever is in
            flight is therefore asked to stop, and waited for, before the pool is closed.
    #>
    param(
        [int]$StopTimeoutSeconds = 15,

        # Leaves ShuttingDown clear: nothing resets it, so setting it here would refuse every
        # later action for the rest of the session
        [switch]$Recycle
    )

    if ($null -eq $sync) {
        return
    }

    $poolLock = Get-WinUtilRunspacePoolLock
    [System.Threading.Monitor]::Enter($poolLock)
    try {
        # Set before stopping, so nothing that is winding down queues fresh work behind us
        if (-not $Recycle) {
            $sync.ShuttingDown = $true
        }

        if (-not $sync.ContainsKey("runspace") -or $null -eq $sync.runspace) {
            return
        }

        $stopped = $true
        try {
            $stopped = Stop-WinUtilActiveWork -TimeoutSeconds $StopTimeoutSeconds
        } catch {
            $stopped = $false
            Write-WinUtilLog -Level "WARN" -Component "UI" -Message "Could not stop running work cleanly: $($_.Exception.Message)"
        }

        $pool = $sync.runspace
        $cleanupDeferred = $false
        try {
            $poolState = $pool.RunspacePoolStateInfo.State
            $terminalStates = @(
                [System.Management.Automation.Runspaces.RunspacePoolState]::Closed,
                [System.Management.Automation.Runspaces.RunspacePoolState]::Broken
            )

            if (-not $stopped -and $poolState -notin $terminalStates) {
                # Close and Dispose both wait for an invocation that ignored BeginStop. Hand
                # cleanup to the thread pool so the timeout above remains a real upper bound.
                $cleanupDeferred = $true
                if ($poolState -ne [System.Management.Automation.Runspaces.RunspacePoolState]::Closing) {
                    Register-WinUtilRunspacePoolCleanup -RunspacePool $pool
                }
            } elseif ($poolState -notin ($terminalStates + [System.Management.Automation.Runspaces.RunspacePoolState]::Closing)) {
                $pool.Close()
            }
        } catch {
            # A pool that will not close cleanly must not stop the window from closing
            Write-WinUtilLog -Level "WARN" -Component "UI" -Message "Worker pool did not close cleanly: $($_.Exception.Message)"
        } finally {
            if (-not $cleanupDeferred) {
                try {
                    $pool.Dispose()
                } catch {
                    Write-WinUtilLog -Level "WARN" -Component "UI" -Message "Worker pool did not dispose cleanly: $($_.Exception.Message)"
                }
            }
            $sync.Remove("runspace")
            if ($sync.ActiveShells) { $sync.ActiveShells.Clear() }
        }
    } finally {
        [System.Threading.Monitor]::Exit($poolLock)
    }
}

function Register-WinUtilRunspacePoolCleanup {
    <#
        .SYNOPSIS
            Closes and disposes a worker pool without blocking the calling thread
    #>
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.Runspaces.RunspacePool]$RunspacePool
    )

    if (-not ("WinUtilRunspacePoolCleanup" -as [type])) {
        Add-Type @"
using System;
using System.Management.Automation.Runspaces;

public sealed class WinUtilRunspacePoolCleanupState
{
    public RunspacePool RunspacePool { get; set; }
    public IAsyncResult Handle { get; set; }
}

public static class WinUtilRunspacePoolCleanup
{
    public static readonly System.Threading.WaitOrTimerCallback Callback = Cleanup;

    public static void Cleanup(object state, bool timedOut)
    {
        var cleanupState = state as WinUtilRunspacePoolCleanupState;
        if (cleanupState == null || cleanupState.RunspacePool == null || cleanupState.Handle == null)
        {
            return;
        }

        try
        {
            cleanupState.RunspacePool.EndClose(cleanupState.Handle);
        }
        catch
        {
        }
        finally
        {
            try
            {
                cleanupState.RunspacePool.Dispose();
            }
            catch
            {
            }
        }
    }
}
"@
    }

    $cleanupState = [WinUtilRunspacePoolCleanupState]::new()
    $cleanupState.RunspacePool = $RunspacePool
    $cleanupState.Handle = $RunspacePool.BeginClose($null, $null)
    [System.Threading.ThreadPool]::RegisterWaitForSingleObject(
        $cleanupState.Handle.AsyncWaitHandle,
        [WinUtilRunspacePoolCleanup]::Callback,
        $cleanupState,
        -1,
        $true
    ) | Out-Null
}

function Convert-WinUtilTextEncoding {
    param([AllowNull()][object]$Text)

    # Windows PowerShell 5.1 reads UTF-8 scripts without a BOM as ANSI. This
    # can corrupt string literals when a source file is dot-sourced directly.
    # Only repair the typical UTF-8-as-Windows-1252 markers in UI strings.
    if ($Text -isnot [string] -or [string]::IsNullOrEmpty($Text)) { return $Text }
    if ($Text.IndexOf([char]0x00C3) -lt 0 -and
        $Text.IndexOf([char]0x00C2) -lt 0 -and
        $Text.IndexOf([char]0x00E2) -lt 0) {
        return $Text
    }

    try {
        $windows1252 = [Text.Encoding]::GetEncoding(1252, [Text.EncoderFallback]::ExceptionFallback, [Text.DecoderFallback]::ExceptionFallback)
        $utf8 = [Text.UTF8Encoding]::new($false, $true)
        $restored = $utf8.GetString($windows1252.GetBytes($Text))
        if ($restored -ne $Text) { return $restored }
    } catch [Text.EncoderFallbackException] {
        # Normal Unicode outside code page 1252 is not mojibake.
    } catch [Text.DecoderFallbackException] {
        # An invalid UTF-8 sequence is evidence that the original text was fine.
    }
    return $Text
}

function Find-TweaksByNameOrDescription {
    <#
        .SYNOPSIS
            Searches through the Tweaks on the Tweaks Tab and hides all entries that do not match the search string

        .DESCRIPTION
            Filters tweak entries by name or description using literal string matching (no wildcard expansion).
            Respects collapsed category state and handles null $sync gracefully.
            Safe for rapid keystroke events; no terminal spam on error conditions.

        .PARAMETER SearchString
            The string to be searched for. Wildcards are treated as literal characters.

        .NOTES
            - Uses module-scope $sync (resolved via global/script fallback if needed)
            - Performs literal matching (no wildcard expansion)
            - Safely handles missing UI elements and null properties
            - Protected by try/catch to prevent UI thread crashes
            - PowerShell 5.1 compatible (no ternary operators, no advanced language features)
    #>
    param(
        [Parameter(Mandatory = $false)]
        [string]$SearchString = ""
    )

    # ------------------------------------------------------------------------------
    # 1. RESOLVE $SYNC WITH MULTI-LEVEL FALLBACK
    # ------------------------------------------------------------------------------

    if ($null -eq $Sync) {
        $Sync = $global:sync
        if ($null -eq $Sync) {
            $Sync = $script:sync
        }
    }

    # Validate that $Sync exists and has required structure
    if ($null -eq $Sync) {
        # Silent return - function called on every keystroke; no warning spam
        return
    }

    if ($null -eq $Sync.Form) {
        # Silent return - form not yet initialized
        return
    }

    # ------------------------------------------------------------------------------
    # 2. GET REFERENCE TO TWEAKS OR APPX PANEL
    # ------------------------------------------------------------------------------

    $panelName = "tweakspanel"
    if ($null -ne $Sync.currentTab -and $Sync.currentTab -eq "AppX") {
        $panelName = "appxpanel"
    }

    $tweaksPanel = $null
    try {
        $tweaksPanel = $Sync.Form.FindName($panelName)
    }
    catch {
        # Silent return - panel not found or disposed
        return
    }

    if ($null -eq $tweaksPanel) {
        # Silent return - panel doesn't exist
        return
    }

    # ------------------------------------------------------------------------------
    # 3. HANDLE EMPTY/WHITESPACE SEARCH STRING - RESET TO DEFAULT STATE
    # ------------------------------------------------------------------------------

    if ([string]::IsNullOrWhiteSpace($SearchString)) {
        try {
            $tweaksPanel.Children | ForEach-Object {
                $categoryBorder = $_

                # Safely set visibility
                if ($null -ne $categoryBorder) {
                    $categoryBorder.Visibility = [Windows.Visibility]::Visible
                }

                # Process each category
                if ($categoryBorder -is [Windows.Controls.Border]) {
                    $dockPanel = $null
                    if ($null -ne $categoryBorder.Child) {
                        $dockPanel = $categoryBorder.Child
                    }

                    if ($dockPanel -is [Windows.Controls.DockPanel]) {
                        $container = $dockPanel.Children | Where-Object { $_ -is [Windows.Controls.ItemsControl] -or $_ -is [Windows.Controls.StackPanel] -or $_ -is [Windows.Controls.ScrollViewer] -or $_.GetType().Name -eq "ItemsControl" } | Select-Object -First 1

                        if ($null -ne $container) {
                            $targetPanel = if ($container.PSObject.Properties['Content'] -and $null -ne $container.Content) { $container.Content } else { $container }
                            $items = $null
                            if ($targetPanel -is [Windows.Controls.ItemsControl] -or $targetPanel.GetType().Name -eq "ItemsControl") {
                                $items = $targetPanel.Items
                            }
                            else {
                                $items = $targetPanel.Children
                            }
                            # Show all items in the category
                            foreach ($item in $items) {
                                if ($null -ne $item) {
                                    # Check if it's a category label (first Label in the container)
                                    if ($item -is [Windows.Controls.Label] -or $item.GetType().Name -eq "Label") {
                                        $item.Visibility = [Windows.Visibility]::Visible
                                    }
                                    elseif ($item -is [Windows.Controls.DockPanel] -or $item -is [Windows.Controls.StackPanel] -or $item.GetType().Name -eq "DockPanel" -or $item.GetType().Name -eq "StackPanel") {
                                        # Show all checkbox containers
                                        $item.Visibility = [Windows.Visibility]::Visible
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        catch {
            # Silent catch - UI element may be disposed
            $null = $_
        }

        return
    }

    # ------------------------------------------------------------------------------
    # 4. PERFORM LITERAL SEARCH (NO WILDCARD EXPANSION)
    # ------------------------------------------------------------------------------

    try {
        # Normalize search term once for the entire operation
        $searchTerm = $SearchString
        if ($null -eq $searchTerm) {
            $searchTerm = ""
        }

        # Iterate through all categories
        $tweaksPanel.Children | ForEach-Object {
            $categoryBorder = $_
            $categoryHasMatch = $false

            if ($categoryBorder -is [Windows.Controls.Border]) {
                $dockPanel = $null
                if ($null -ne $categoryBorder.Child) {
                    $dockPanel = $categoryBorder.Child
                }

                if ($dockPanel -is [Windows.Controls.DockPanel]) {
                    $container = $dockPanel.Children | Where-Object { $_ -is [Windows.Controls.ItemsControl] -or $_ -is [Windows.Controls.StackPanel] -or $_ -is [Windows.Controls.ScrollViewer] -or $_.GetType().Name -eq "ItemsControl" } | Select-Object -First 1

                    if ($null -ne $container) {
                        $categoryLabel = $null

                        $targetPanel = if ($container.PSObject.Properties['Content'] -and $null -ne $container.Content) { $container.Content } else { $container }
                        $items = $null
                        if ($targetPanel -is [Windows.Controls.ItemsControl] -or $targetPanel.GetType().Name -eq "ItemsControl") {
                            $items = $targetPanel.Items
                        }
                        else {
                            $items = $targetPanel.Children
                        }
                        # Process all items (checkboxes, labels, panels) in the container
                        foreach ($item in $items) {
                            if ($null -eq $item) {
                                continue
                            }

                            # ------------------------------------------------------------
                            # Check if this is a category label (usually first Label)
                            # ------------------------------------------------------------

                            if ($item -is [Windows.Controls.Label] -or $item.GetType().Name -eq "Label") {
                                $categoryLabel = $item
                                # Initially hide category label; show it only if matches found
                                $item.Visibility = [Windows.Visibility]::Collapsed
                            }

                            # ------------------------------------------------------------
                            # Check if this is a DockPanel containing a tweak checkbox
                            # ------------------------------------------------------------

                            elseif ($item -is [Windows.Controls.DockPanel] -or $item.GetType().Name -eq "DockPanel") {
                                $checkbox = $null
                                $label = $null

                                # Safely extract checkbox and label
                                $checkbox = $item.Children | Where-Object { $_ -is [Windows.Controls.CheckBox] -or $_.GetType().Name -eq "CheckBox" } | Select-Object -First 1
                                $label = $item.Children | Where-Object { $_ -is [Windows.Controls.Label] -or $_.GetType().Name -eq "Label" } | Select-Object -First 1

                                # Check if tweak matches search criteria
                                $itemMatches = $false

                                if ($null -ne $label) {
                                    $labelContent = $label.Content
                                    $labelToolTip = $label.ToolTip

                                    # Safely null-check properties
                                    if ($null -eq $labelContent) {
                                        $labelContent = ""
                                    }
                                    if ($null -eq $labelToolTip) {
                                        $labelToolTip = ""
                                    }

                                    # Convert to string and perform LITERAL matching
                                    $labelContentStr = [string]$labelContent
                                    $labelToolTipStr = [string]$labelToolTip

                                    # Use IndexOf for literal matching (no wildcard interpretation)
                                    $contentMatch = $labelContentStr.IndexOf($searchTerm, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
                                    $toolTipMatch = $labelToolTipStr.IndexOf($searchTerm, [System.StringComparison]::OrdinalIgnoreCase) -ge 0

                                    if ($contentMatch -or $toolTipMatch) {
                                        $itemMatches = $true
                                    }
                                }

                                # Set visibility based on match result
                                if ($itemMatches) {
                                    $item.Visibility = [Windows.Visibility]::Visible
                                    $categoryHasMatch = $true
                                }
                                else {
                                    $item.Visibility = [Windows.Visibility]::Collapsed
                                }
                            }

                            # ------------------------------------------------------------
                            # Check if this is a StackPanel containing a tweak checkbox
                            # ------------------------------------------------------------

                            elseif ($item -is [Windows.Controls.StackPanel] -or $item.GetType().Name -eq "StackPanel") {
                                $checkbox = $null
                                $checkbox = $item.Children | Where-Object { $_ -is [Windows.Controls.CheckBox] -or $_.GetType().Name -eq "CheckBox" } | Select-Object -First 1

                                # Nested service groups keep their checkbox inside a
                                # subheader, so search the text on the wrapper as well.
                                $itemMatches = ($item.Tag -is [string]) -and
                                    ($item.Tag.IndexOf($searchTerm, [System.StringComparison]::OrdinalIgnoreCase) -ge 0)

                                if ($null -ne $checkbox) {
                                    $checkboxContent = $checkbox.Content
                                    $checkboxToolTip = $checkbox.ToolTip

                                    # Safely null-check properties
                                    if ($null -eq $checkboxContent) {
                                        $checkboxContent = ""
                                    }
                                    if ($null -eq $checkboxToolTip) {
                                        $checkboxToolTip = ""
                                    }

                                    # Convert to string and perform LITERAL matching
                                    $checkboxContentStr = [string]$checkboxContent
                                    $checkboxToolTipStr = [string]$checkboxToolTip

                                    # Use IndexOf for literal matching (no wildcard interpretation)
                                    $contentMatch = $checkboxContentStr.IndexOf($searchTerm, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
                                    $toolTipMatch = $checkboxToolTipStr.IndexOf($searchTerm, [System.StringComparison]::OrdinalIgnoreCase) -ge 0

                                    if ($contentMatch -or $toolTipMatch) {
                                        $itemMatches = $true
                                    }
                                }

                                # Set visibility based on match result
                                if ($itemMatches) {
                                    $item.Visibility = [Windows.Visibility]::Visible
                                    $categoryHasMatch = $true
                                }
                                else {
                                    $item.Visibility = [Windows.Visibility]::Collapsed
                                }
                            }
                        }

                        # ------------------------------------------------------------
                        # Update category label visibility and expanded/collapsed state
                        # ------------------------------------------------------------

                        if ($categoryHasMatch) {
                            # Show category label
                            if ($null -ne $categoryLabel) {
                                $categoryLabel.Visibility = [Windows.Visibility]::Visible

                                # Update category label to expanded state (change "+" to "-")
                                $labelContent = $categoryLabel.Content
                                if ($null -ne $labelContent) {
                                    $labelStr = [string]$labelContent

                                    # Safe string replacement without -replace regex
                                    if ($labelStr.StartsWith("+ ")) {
                                        $expandedLabel = "- " + $labelStr.Substring(2)
                                        $categoryLabel.Content = $expandedLabel
                                    }
                                }
                            }
                        }
                    }
                }

                # ----------------------------------------------------------------
                # Set category border visibility based on whether it has matches
                # ----------------------------------------------------------------

                if ($categoryHasMatch) {
                    $categoryBorder.Visibility = [Windows.Visibility]::Visible
                }
                else {
                    $categoryBorder.Visibility = [Windows.Visibility]::Collapsed
                }
            }
        }
    }
    catch {
        # Silent catch - UI elements may be disposed or in unexpected state
        # Do not log to terminal as this function is called on every keystroke
        $null = $_
    }
}

function Get-WinUtilAboutInfo {
    param(
        [ValidateSet('en', 'es')][string]$Language = 'en',
        [string]$Version = ''
    )

    if ($Language -eq 'es') {
        return @"
APBOptimizer - Versión: $Version

Créditos y agradecimientos
Un saludo a Chris Titus Tech y a toda la comunidad que hizo posible WinUtil.
¡Gracias por compartir WinUtil como software libre! APBOptimizer está basado en ese trabajo.

Proyecto original: <a href="https://github.com/ChrisTitusTech/winutil">ChrisTitusTech/winutil</a>
Licencia original: <a href="https://github.com/ChrisTitusTech/winutil/blob/main/LICENSE">Ver licencia MIT</a>
Licencia MIT · Copyright (c) 2022 CT Tech Group LLC.
El aviso de copyright y el texto completo de la licencia se conservan en el archivo LICENSE de APBOptimizer.

Colaboradores de WinUtil:
Autor: <a href="https://github.com/ChrisTitusTech">@ChrisTitusTech</a>
Interfaz: <a href="https://github.com/MyDrift-user">@MyDrift-user</a>, <a href="https://github.com/Marterich">@Marterich</a>
Runspace: <a href="https://github.com/DeveloperDurp">@DeveloperDurp</a>, <a href="https://github.com/Marterich">@Marterich</a>

APBOptimizer es un fork independiente; no está afiliado ni respaldado por Chris Titus Tech.
"@
    }

    return @"
APBOptimizer - Version: $Version

Credits and acknowledgements
Greetings to Chris Titus Tech and everyone who made WinUtil possible.
Thank you for sharing WinUtil as open-source software! APBOptimizer is based on that work.

Original project: <a href="https://github.com/ChrisTitusTech/winutil">ChrisTitusTech/winutil</a>
Original license: <a href="https://github.com/ChrisTitusTech/winutil/blob/main/LICENSE">View MIT license</a>
MIT License · Copyright (c) 2022 CT Tech Group LLC.
The original copyright notice and full license text are kept in APBOptimizer's LICENSE file.

WinUtil contributors:
Author: <a href="https://github.com/ChrisTitusTech">@ChrisTitusTech</a>
UI: <a href="https://github.com/MyDrift-user">@MyDrift-user</a>, <a href="https://github.com/Marterich">@Marterich</a>
Runspace: <a href="https://github.com/DeveloperDurp">@DeveloperDurp</a>, <a href="https://github.com/Marterich">@Marterich</a>

APBOptimizer is an independent fork and is not affiliated with or endorsed by Chris Titus Tech.
"@
}

function Get-WinUtilDNSBenchmark {
    <#

    .SYNOPSIS
        Benchmarks neutral DNS providers by measuring TCP port 53 latency (RTT in ms) to determine the fastest DNS server.

    .PARAMETER TimeoutMs
        Maximum timeout in milliseconds for each connection test. Default is 1500ms.

    .OUTPUTS
        Array of PSCustomObjects containing Provider, PrimaryIP, and LatencyMs sorted by lowest latency.

    .EXAMPLE
        $results = Get-WinUtilDNSBenchmark
        $fastest = $results[0]

    #>
    [CmdletBinding()]
    param(
        [ValidateRange(1, 9998)]
        [int]$TimeoutMs = 1500
    )

    Write-WinUtilLog -Component "DNS" -Message "Starting DNS latency benchmark scan (TCP port 53)..."

    $dnsConfigs = $sync.configs.dns
    if ($null -eq $dnsConfigs) {
        Write-Warning "DNS configurations not found in `$sync.configs.dns."
        Write-WinUtilLog -Level "ERROR" -Component "DNS" -Message "DNS configurations not found in `$sync.configs.dns."
        return @()
    }

    $results = [System.Collections.Generic.List[PSObject]]::new()

    foreach ($prop in $dnsConfigs.PSObject.Properties) {
        $providerName = $prop.Name
        $primaryIp = $prop.Value.Primary
        if (-not $primaryIp) { continue }

        # Providers must explicitly opt in so new filtering services are never auto-selected.
        if ($prop.Value.BenchmarkEligible -ne $true) {
            continue
        }

        $latency = 9999
        $client = $null
        try {
            $client = New-Object System.Net.Sockets.TcpClient
            $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            $asyncResult = $client.BeginConnect($primaryIp, 53, $null, $null)
            $success = $asyncResult.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
            $stopwatch.Stop()

            if ($success) {
                $client.EndConnect($asyncResult)
                $latency = [int]$stopwatch.ElapsedMilliseconds
            } else {
                $latency = 9999
            }
        } catch {
            $latency = 9999
        } finally {
            if ($null -ne $client) {
                $client.Dispose()
            }
        }

        $results.Add([PSCustomObject]@{
            Provider  = $providerName
            PrimaryIP = $primaryIp
            LatencyMs = $latency
        })
    }

    $sortedResults = @($results | Sort-Object LatencyMs)
    if ($sortedResults.Count -gt 0 -and $sortedResults[0].LatencyMs -lt 9999) {
        $fastest = $sortedResults[0]
        Write-WinUtilLog -Component "DNS" -Message "DNS Benchmark completed. Fastest neutral provider: $($fastest.Provider) ($($fastest.LatencyMs) ms)"
    } else {
        Write-WinUtilLog -Component "DNS" -Message "DNS Benchmark completed. Could not determine latency for providers."
    }

    return $sortedResults
}

function Get-WinUtilEntryToolTip {
    <#
        .SYNOPSIS
            Builds the tooltip string for an app/tweak/feature entry: its description plus its preset JSON key

        .PARAMETER Description
            The entry's description from the config JSON. May be null or empty.

        .PARAMETER Key
            The entry's JSON key as used in preset files (e.g. WPFInstallbrave, WPFTweaksTele).
    #>
    param(
        [Parameter(Mandatory = $false)]
        [string]$Description,

        [Parameter(Mandatory = $true)]
        [string]$Key
    )

    if ([string]::IsNullOrWhiteSpace($Description)) {
        return "Preset key: $Key"
    }

    return "$Description`n`nPreset key: $Key"
}

function Get-WinUtilPendingGroupChanges {
    # Snapshot service/driver selections on the UI thread. Checkbox handlers
    # only edit this synchronized table, never touch Windows.
    if ($null -eq $sync.PendingGroupSelections) { return @() }
    [System.Threading.Monitor]::Enter($sync.PendingGroupSelections.SyncRoot)
    try {
        return @($sync.PendingGroupSelections.GetEnumerator() | ForEach-Object {
            [pscustomobject]@{ Key = [string]$_.Key; Disable = [bool]$_.Value }
        })
    } finally {
        [System.Threading.Monitor]::Exit($sync.PendingGroupSelections.SyncRoot)
    }
}

function Invoke-WinUtilPendingGroupChanges {
    param([object[]]$Changes)
    foreach ($change in @($Changes)) {
        $key = [string]$change.Key
        $property = $sync.configs.tweaks.PSObject.Properties[$key]
        if (-not $property -or $property.Value.ParentGroup -notin @('WPFServiceGroupDiagnostics', 'WPFServiceGroupUseless', 'WPFDriverGroupOptional')) {
            throw "Invalid service/driver group selection '$key'."
        }
        $entry = $property.Value
        if (-not $entry.driver.Name -and -not $entry.service) {
            throw "Invalid service/driver group member '$key'."
        }

        $desired = [bool]$change.Disable
        # One refused service must not abort the rest of the run. The failure is
        # logged and counted, and its pending entry stays queued for retry.
        try {
            $actual = Get-WinUtilToggleStatus -ToggleSwitch $key -BypassCache -StopOnReadError
            if ($actual -ne $desired) {
                Invoke-WinUtilTweaks -CheckBox $key -undo (-not $desired)
            }
            $verified = Get-WinUtilToggleStatus -ToggleSwitch $key -BypassCache -StopOnReadError
            if ($verified -ne $desired) {
                # Set-WinUtilService only warns, so name the state Windows kept.
                $detail = if ($entry.service) {
                    $observed = @($entry.service | ForEach-Object {
                        $service = Get-Service -Name $_.Name -ErrorAction SilentlyContinue
                        $startType = if ($service) { [string]$service.StartType } else { 'missing' }
                        $expected = if ($desired) { $_.StartupType } else { $_.OriginalType }
                        "$($_.Name) startup is $startType (expected $expected)"
                    }) -join '; '
                    " $observed."
                } else { '' }
                throw "Could not verify the selected service/driver state for '$key'.$detail"
            }
        } catch {
            Write-WinUtilErrorRecord -ErrorRecord $_ -Component 'Tweaks' -Context "Service/driver change $key"
            continue
        }
        if ($null -ne $sync.ToggleStatusCache) {
            $sync.ToggleStatusCache[$key] = $verified
        }
        if ($null -ne $sync.PendingGroupSelections) {
            [System.Threading.Monitor]::Enter($sync.PendingGroupSelections.SyncRoot)
            try {
                if ($sync.PendingGroupSelections.ContainsKey($key) -and
                    [bool]$sync.PendingGroupSelections[$key] -eq $desired) {
                    $sync.PendingGroupSelections.Remove($key)
                }
            } finally {
                [System.Threading.Monitor]::Exit($sync.PendingGroupSelections.SyncRoot)
            }
        }
    }
}

function Get-WinUtilPendingTaskChanges {
    # Take a snapshot on the UI thread before passing it to the job. The
    # scheduler is modified only by the Apply worker, never by checkbox events.
    if ($null -eq $sync.PendingTaskSelections) { return @() }
    [System.Threading.Monitor]::Enter($sync.PendingTaskSelections.SyncRoot)
    try {
        return @($sync.PendingTaskSelections.GetEnumerator() | ForEach-Object {
            [pscustomobject]@{ Key = [string]$_.Key; Disable = [bool]$_.Value }
        })
    } finally {
        [System.Threading.Monitor]::Exit($sync.PendingTaskSelections.SyncRoot)
    }
}

function Invoke-WinUtilPendingTaskChanges {
    param([object[]]$Changes)
    foreach ($change in @($Changes)) {
        $key = [string]$change.Key
        $entry = $sync.configs.tweaks.PSObject.Properties[$key]
        if (-not $entry -or $entry.Value.ParentGroup -ne 'WPFTaskGroupTelemetry' -or
            -not $entry.Value.scheduledTask.Name) {
            throw "Invalid scheduled-task selection '$key'."
        }

        $desired = [bool]$change.Disable
        $actual = Get-WinUtilToggleStatus -ToggleSwitch $key -BypassCache -StopOnReadError
        if ($actual -ne $desired) {
            Invoke-WinUtilTweaks $key -undo (-not $desired)
        }

        # Verify even when the previous operation was a no-op. Do not discard
        # pending work or report success if scheduler access was denied.
        $verified = Get-WinUtilToggleStatus -ToggleSwitch $key -BypassCache -StopOnReadError
        if ($verified -ne $desired) {
            throw "Could not apply the selected scheduled-task state for '$key'."
        }
        if ($null -ne $sync.ToggleStatusCache) { $sync.ToggleStatusCache[$key] = $verified }
        if ($null -ne $sync.PendingTaskSelections) {
            [System.Threading.Monitor]::Enter($sync.PendingTaskSelections.SyncRoot)
            try {
                if ($sync.PendingTaskSelections.ContainsKey($key) -and
                    [bool]$sync.PendingTaskSelections[$key] -eq $desired) {
                    $sync.PendingTaskSelections.Remove($key)
                }
            } finally {
                [System.Threading.Monitor]::Exit($sync.PendingTaskSelections.SyncRoot)
            }
        }
    }
}

function Get-WinUtilRecentLogs {
    <#
    .SYNOPSIS
        Concatenates WinUtil session logs from the last N days into a single text blob.

    .PARAMETER Days
        How many days back to include. Defaults to 7, matching what the support forum/server
        typically asks users for.

    .PARAMETER LogDirectory
        Overrides the log directory (normally $sync.winutildir\logs). Mainly for testing.
    #>
    param(
        [int]$Days = 7,
        [string]$LogDirectory
    )

    if ([string]::IsNullOrWhiteSpace($LogDirectory)) {
        if ($null -eq $sync -or -not $sync.ContainsKey("winutildir") -or [string]::IsNullOrWhiteSpace($sync.winutildir)) {
            return ""
        }
        $LogDirectory = Join-Path $sync.winutildir "logs"
    }

    if (-not (Test-Path -LiteralPath $LogDirectory -ErrorAction Stop)) {
        return ""
    }

    $cutoff = (Get-Date).AddDays(-$Days)
    $logFiles = Get-ChildItem -LiteralPath $LogDirectory -Filter "winutil_*.log" -File -ErrorAction Stop |
        Where-Object { $_.LastWriteTime -ge $cutoff } |
        Sort-Object LastWriteTime

    $sections = foreach ($logFile in $logFiles) {
        "=== $($logFile.Name) ===`n$(Get-Content -LiteralPath $logFile.FullName -Raw -ErrorAction Stop)"
    }

    return ($sections -join "`n`n")
}

function Get-WinUtilRegistryComboState {
    <#
    .SYNOPSIS
        Finds the configured combo-box state matching the current registry values.

    .PARAMETER Registry
        Registry settings containing a value mapping for each supported state.

    .OUTPUTS
        The name of the matching state.
    #>
    param(
        [Parameter(Mandatory)]
        $Registry
    )

    foreach ($state in $Registry[0].Values.PSObject.Properties) {
        $stateMatches = $true
        foreach ($setting in @($Registry)) {
            $currentValue = Get-WinUtilRegistryComboValue -Setting $setting
            $actualValue = if ($currentValue.Exists -and $null -ne $currentValue.Value) { $currentValue.Value } else { $setting.DefaultValue }
            $configuredValue = $setting.Values.PSObject.Properties[$state.Name].Value
            # Removal represents the effective Windows default when matching the current state.
            $expectedValue = if ($configuredValue -eq "<RemoveEntry>") { $setting.DefaultValue } else { $configuredValue }
            if ([string]$actualValue -ne [string]$expectedValue) {
                $stateMatches = $false
                break
            }
        }
        if ($stateMatches) {
            return $state.Name
        }
    }

    throw "Registry values do not match a supported state."
}

function Get-WinUtilRegistryComboValue {
    <#
    .SYNOPSIS
        Reads one registry value for a registry-backed combo-box state.

    .PARAMETER Setting
        The registry setting from the combo-box configuration.
    #>
    param(
        [Parameter(Mandatory)]
        $Setting
    )

    try {
        $item = Get-ItemProperty -Path $Setting.Path -Name $Setting.Name -ErrorAction Stop
        $property = $item.PSObject.Properties[$Setting.Name]
        return [pscustomobject]@{ Exists = $null -ne $property; Value = $property.Value }
    } catch [System.Management.Automation.PSArgumentException] {
        # The registry provider uses PSArgumentException when a named value is absent.
        return [pscustomobject]@{ Exists = $false; Value = $null }
    } catch [System.Management.Automation.ItemNotFoundException] {
        return [pscustomobject]@{ Exists = $false; Value = $null }
    }
}

function Get-WinUtilRunspacePoolLock {
    <#
        .SYNOPSIS
            Returns the lock that serializes worker-pool startup and shutdown
    #>

    [System.Threading.Monitor]::Enter($sync.SyncRoot)
    try {
        if ($null -eq $sync.RunspacePoolLock) {
            $sync.RunspacePoolLock = [object]::new()
        }

        return $sync.RunspacePoolLock
    } finally {
        [System.Threading.Monitor]::Exit($sync.SyncRoot)
    }
}

Function Get-WinUtilToggleStatus {
    param(
        $ToggleSwitch,
        [switch]$BypassCache,
        [switch]$StopOnReadError
    )

    $ToggleSwitchReg = $sync.configs.tweaks.$ToggleSwitch.registry
    $ToggleSwitchServices = $sync.configs.tweaks.$ToggleSwitch.service
    $ToggleSwitchDriver = $sync.configs.tweaks.$ToggleSwitch.driver
    $ToggleSwitchTask = $sync.configs.tweaks.$ToggleSwitch.scheduledTask

    if (-not $BypassCache) {
        if ($null -eq $sync.ToggleStatusCache) {
            $sync.ToggleStatusCache = @{}
        }

        if ($sync.ToggleStatusCache.ContainsKey($ToggleSwitch)) {
            return [bool]$sync.ToggleStatusCache[$ToggleSwitch]
        }
    }

    $readErrorAction = if ($StopOnReadError) { "Stop" } else { "Continue" }

    if ($ToggleSwitchTask) {
        try {
            $info = Get-WinUtilTelemetryTaskInfo -Name $ToggleSwitchTask.Name
            $disabled = [bool]$info.Disabled
        } catch {
            if ($StopOnReadError) { throw }
            Write-WinUtilLog -Level 'WARN' -Component 'Tasks' -Message "Cannot read task '$($ToggleSwitchTask.Name)': $($_.Exception.Message)"
            $disabled = $false
        }
        if (-not $BypassCache) { $sync.ToggleStatusCache[$ToggleSwitch] = $disabled }
        return $disabled
    }

    if ($ToggleSwitchDriver) {
        $info = Get-WinUtilOptionalDriverInfo -Name $ToggleSwitchDriver.Name
        $enabled = [bool]$info.Disabled
        if (-not $BypassCache) { $sync.ToggleStatusCache[$ToggleSwitch] = $enabled }
        return $enabled
    }

    # The grouped service switches use the same Toggle selection/export system,
    # but their state is a service startup type instead of a registry value.
    if ($ToggleSwitchServices -and -not $ToggleSwitchReg) {
        $enabled = $true
        foreach ($serviceEntry in $ToggleSwitchServices) {
            $service = Get-Service -Name $serviceEntry.Name -ErrorAction $(if ($StopOnReadError) { 'Stop' } else { 'SilentlyContinue' })
            if ($null -eq $service -or [string]$service.StartType -ne [string]$serviceEntry.StartupType) {
                $enabled = $false
                break
            }
        }
        if (-not $BypassCache) { $sync.ToggleStatusCache[$ToggleSwitch] = $enabled }
        return $enabled
    }

    if (-not (Get-PSDrive -Name HKU -ErrorAction SilentlyContinue)) {
        New-PSDrive -PSProvider Registry -Name HKU -Root HKEY_USERS -ErrorAction $readErrorAction | Out-Null
    }

    foreach ($regentry in $ToggleSwitchReg) {

        if (Test-Path $regentry.Path -ErrorAction $readErrorAction) {
            $regstate = (Get-ItemProperty -Path $regentry.Path -ErrorAction $readErrorAction).$($regentry.Name)
        } else {
            $regstate = $null
        }

        if ($null -eq $regstate) {
            switch ([string]$regentry.DefaultState) {
                "true"  { $regstate = $regentry.Value }
                "false" { $regstate = $regentry.OriginalValue }
            }
        }

        if ($regstate -ne $regentry.Value) {
            if (-not $BypassCache) {
                $sync.ToggleStatusCache[$ToggleSwitch] = $false
            }
            return $false
        }
    }

    if (-not $BypassCache) {
        $sync.ToggleStatusCache[$ToggleSwitch] = $true
    }
    return $true
}

function Get-WinUtilTweaksStateReport {
    <#
    .SYNOPSIS
        Groups every config/tweaks.json entry's live applied state by category, reusing the same
        detection Invoke-WPFGetInstalled uses to check the "Select Installed Tweaks" checkboxes.
    #>

    $categoryFieldNames = [ordered]@{
        "Essential Tweaks"                    = "essentialTweaks"
        "Customize Preferences"               = "customizePreferences"
        "z__Advanced Tweaks - CAUTION"         = "advancedTweaks"
        "Performance Plans - NOT FOR LAPTOPS" = "performancePlans"
    }

    $grouped = [ordered]@{}
    foreach ($fieldName in $categoryFieldNames.Values) {
        $grouped[$fieldName] = [ordered]@{}
    }
    $notEvaluable = [System.Collections.Generic.List[string]]::new()
    $collectionStatus = "collected"

    try {
        $appliedTweaks = [System.Collections.Generic.HashSet[string]]::new(
            [string[]]@(Invoke-WinUtilCurrentSystem -CheckBox "tweaks" `
                -BypassToggleStatusCache -StopOnReadError)
        )

        foreach ($property in $sync.configs.tweaks.PSObject.Properties) {
            $tweakKey = $property.Name
            $entry = $property.Value
            $fieldName = $categoryFieldNames[[string]$entry.category]

            # Buttons embedded in the tweaks panel (e.g. Ultimate Performance launchers)
            # are actions, not stateful tweaks, so they're outside this report's scope entirely.
            if (-not $fieldName -or $entry.Type -eq "Button") {
                continue
            }

            # Combobox tweaks and script-only tweaks with no registry/service schema have no
            # detectable current state. List them so the report doesn't silently drop them.
            if ($entry.Type -eq "Combobox" -or (-not $entry.registry -and -not $entry.service)) {
                $notEvaluable.Add($tweakKey)
                continue
            }

            $grouped[$fieldName][$tweakKey] = $appliedTweaks.Contains($tweakKey)
        }
    } catch {
        Write-WinUtilLog -Component "EnvironmentReport" -Level "WARN" -Message "Failed to collect tweaks/toggle state: $($_.Exception.Message)"
        $collectionStatus = "unavailable"
    }

    # Empty groups from a failed collection would otherwise be indistinguishable in the JSON from a
    # successful scan that found nothing notable, so record whether collection actually ran.
    $result = [ordered]@{ collectionStatus = $collectionStatus }
    foreach ($fieldName in $categoryFieldNames.Values) {
        $result[$fieldName] = [pscustomobject]$grouped[$fieldName]
    }
    $result.notEvaluable = @($notEvaluable)

    return [pscustomobject]$result
}

function Get-WinUtilVariables {

    <#
    .SYNOPSIS
        Gets every form object of the provided type

    .OUTPUTS
        List containing every object that matches the provided type
    #>
    param (
        [Parameter()]
        [string[]]$Type
    )
    $keys = ($sync.keys).where{ $_ -like "WPF*" }
    if ($Type) {
        $output = $keys | ForEach-Object {
            try {
                $objType = $sync["$psitem"].GetType().Name
                if ($Type -contains $objType) {
                    Write-Output $psitem
                }
            }
            catch {
                $null = $_
            }
        }
        return $output
    }
    return $keys
}

function Initialize-WinUtilRunspacePool {
    <#
        .SYNOPSIS
            Opens the shared worker pool that Start-WinUtilJob runs job bodies in
    #>

    $poolLock = Get-WinUtilRunspacePoolLock
    [System.Threading.Monitor]::Enter($poolLock)
    try {
        if ($sync.runspace -and $sync.runspace.RunspacePoolStateInfo.State -eq [System.Management.Automation.Runspaces.RunspacePoolState]::Opened) {
            return $sync.runspace
        }

        if ($sync.runspace) {
            # A replacement, not a shutdown
            Close-WinUtilRunspacePool -Recycle
        }

        # Set the maximum number of threads for the RunspacePool to the number of threads on the machine.
        $maxthreads = [Math]::Max([int]$env:NUMBER_OF_PROCESSORS, 1)

        $sync.runspace = [runspacefactory]::CreateRunspacePool(
            1,                            # Minimum thread count
            $maxthreads,                  # Maximum thread count
            (New-WinUtilSessionState),    # Initial session state
            $Host                         # Machine to create runspaces on
        )

        $sync.runspace.Open()
        return $sync.runspace
    } finally {
        [System.Threading.Monitor]::Exit($poolLock)
    }
}

function Initialize-WinUtilTabContent {
    param(
        [Parameter(Mandatory = $true)][string]$TabName,
        [switch]$Yield
    )

    if ($TabName -ne 'Tweaks') { return }

    if ($null -eq $sync.InitializedTabs) { $sync.InitializedTabs = @{} }
    if ($sync.InitializedTabs['Tweaks']) { return }

    $sync.InitializedTabs['Tweaks'] = $true
    try {
        Invoke-WPFUIElements -configVariable $sync.configs.tweaks -targetGridName 'tweakspanel' -columncount 2 -Yield:$Yield
        Reset-WPFCheckBoxes -doToggles $true
    } catch {
        $sync.InitializedTabs['Tweaks'] = $false
        throw
    }
}

function Initialize-WinUtilTaskbarOverlayAssets {
    param(
        [bool]$IncludeLogo = $true,
        [bool]$IncludeStatusAssets = $true
    )

    [System.Threading.Monitor]::Enter($sync.SyncRoot)
    try {
        if ($null -eq $sync.AssetRenderLock) {
            $sync.AssetRenderLock = [object]::new()
        }
        $assetRenderLock = $sync.AssetRenderLock
    } finally {
        [System.Threading.Monitor]::Exit($sync.SyncRoot)
    }

    [System.Threading.Monitor]::Enter($assetRenderLock)
    try {
        if ($IncludeLogo -and -not $sync["logorender"]) {
            $sync["logorender"] = (Invoke-WinUtilAssets -Type "Logo" -Size 90 -Render)
        }

        if ($IncludeStatusAssets -and -not $sync["checkmarkrender"]) {
            $sync["checkmarkrender"] = (Invoke-WinUtilAssets -Type "checkmark" -Size 512 -Render)
        }

        if ($IncludeStatusAssets -and -not $sync["warningrender"]) {
            $sync["warningrender"] = (Invoke-WinUtilAssets -Type "warning" -Size 512 -Render)
        }
    } finally {
        [System.Threading.Monitor]::Exit($assetRenderLock)
    }
}

function Invoke-WinUtilAssets {
  param (
      $type,
      $Size,
      [switch]$render
  )

  if ($render -and $null -ne $sync) {
      if ($null -eq $sync.RenderedAssetCache) {
          $sync.RenderedAssetCache = [Hashtable]::Synchronized(@{})
      }

      $cacheKey = "$(([string]$type).ToLowerInvariant())|$Size"
      if ($sync.RenderedAssetCache.ContainsKey($cacheKey)) {
          return $sync.RenderedAssetCache[$cacheKey]
      }
  }

  # Create the Viewbox and set its size
  $LogoViewbox = New-Object Windows.Controls.Viewbox
  $LogoViewbox.Width = $Size
  $LogoViewbox.Height = $Size

  # Create a Canvas to hold the paths
  $canvas = New-Object Windows.Controls.Canvas
  $canvas.Width = 100
  $canvas.Height = 100

  # Define a scale factor for the content inside the Canvas
  $scaleFactor = $Size / 100

  # Apply a scale transform to the Canvas content
  $scaleTransform = New-Object Windows.Media.ScaleTransform($scaleFactor, $scaleFactor)
  $canvas.LayoutTransform = $scaleTransform

  switch ($type) {
      'logo' {
          $LogoPathData1 = @"
M 18.00,14.00
C 18.00,14.00 45.00,27.74 45.00,27.74
45.00,27.74 57.40,34.63 57.40,34.63
57.40,34.63 59.00,43.00 59.00,43.00
59.00,43.00 59.00,83.00 59.00,83.00
55.35,81.66 46.99,77.79 44.72,74.79
41.17,70.10 42.01,59.80 42.00,54.00
42.00,51.62 42.20,48.29 40.98,46.21
38.34,41.74 25.78,38.60 21.28,33.79
16.81,29.02 18.00,20.20 18.00,14.00 Z
"@
          $LogoPath1 = New-Object Windows.Shapes.Path
          $LogoPath1.Data = [Windows.Media.Geometry]::Parse($LogoPathData1)
          $LogoPath1.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#0567ff")

          $LogoPathData2 = @"
M 107.00,14.00
C 109.01,19.06 108.93,30.37 104.66,34.21
100.47,37.98 86.38,43.10 84.60,47.21
83.94,48.74 84.01,51.32 84.00,53.00
83.97,57.04 84.46,68.90 83.26,72.00
81.06,77.70 72.54,81.42 67.00,83.00
67.00,83.00 67.00,43.00 67.00,43.00
67.00,43.00 67.99,35.63 67.99,35.63
67.99,35.63 80.00,28.26 80.00,28.26
80.00,28.26 107.00,14.00 107.00,14.00 Z
"@
          $LogoPath2 = New-Object Windows.Shapes.Path
          $LogoPath2.Data = [Windows.Media.Geometry]::Parse($LogoPathData2)
          $LogoPath2.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#0567ff")

          $LogoPathData3 = @"
M 19.00,46.00
C 21.36,47.14 28.67,50.71 30.01,52.63
31.17,54.30 30.99,57.04 31.00,59.00
31.04,65.41 30.35,72.16 33.56,78.00
38.19,86.45 46.10,89.04 54.00,93.31
56.55,94.69 60.10,97.20 63.00,97.22
65.50,97.24 68.77,95.36 71.00,94.25
76.42,91.55 84.51,87.78 88.82,83.68
94.56,78.20 95.96,70.59 96.00,63.00
96.01,60.24 95.59,54.63 97.02,52.39
98.80,49.60 103.95,47.87 107.00,47.00
107.00,47.00 107.00,67.00 107.00,67.00
106.90,87.69 96.10,93.85 80.00,103.00
76.51,104.98 66.66,110.67 63.00,110.52
60.33,110.41 55.55,107.53 53.00,106.25
46.21,102.83 36.63,98.57 31.04,93.68
16.88,81.28 19.00,62.88 19.00,46.00 Z
"@
          $LogoPath3 = New-Object Windows.Shapes.Path
          $LogoPath3.Data = [Windows.Media.Geometry]::Parse($LogoPathData3)
          $LogoPath3.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#a3a4a6")

          $canvas.Children.Add($LogoPath1) | Out-Null
          $canvas.Children.Add($LogoPath2) | Out-Null
          $canvas.Children.Add($LogoPath3) | Out-Null
      }
      'checkmark' {
          $canvas.Width = 512
          $canvas.Height = 512

          $scaleFactor = $Size / 2.54
          $scaleTransform = New-Object Windows.Media.ScaleTransform($scaleFactor, $scaleFactor)
          $canvas.LayoutTransform = $scaleTransform

          # Define the circle path
          $circlePathData = "M 1.27,0 A 1.27,1.27 0 1,0 1.27,2.54 A 1.27,1.27 0 1,0 1.27,0"
          $circlePath = New-Object Windows.Shapes.Path
          $circlePath.Data = [Windows.Media.Geometry]::Parse($circlePathData)
          $circlePath.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#39ba00")

          # Define the checkmark path
          $checkmarkPathData = "M 0.873 1.89 L 0.41 1.391 A 0.17 0.17 0 0 1 0.418 1.151 A 0.17 0.17 0 0 1 0.658 1.16 L 1.016 1.543 L 1.583 1.013 A 0.17 0.17 0 0 1 1.599 1 L 1.865 0.751 A 0.17 0.17 0 0 1 2.105 0.759 A 0.17 0.17 0 0 1 2.097 0.999 L 1.282 1.759 L 0.999 2.022 L 0.874 1.888 Z"
          $checkmarkPath = New-Object Windows.Shapes.Path
          $checkmarkPath.Data = [Windows.Media.Geometry]::Parse($checkmarkPathData)
          $checkmarkPath.Fill = [Windows.Media.Brushes]::White

          # Add the paths to the Canvas
          $canvas.Children.Add($circlePath) | Out-Null
          $canvas.Children.Add($checkmarkPath) | Out-Null
      }
      'warning' {
          $canvas.Width = 512
          $canvas.Height = 512

          # Define a scale factor for the content inside the Canvas
          $scaleFactor = $Size / 512  # Adjust scaling based on the canvas size
          $scaleTransform = New-Object Windows.Media.ScaleTransform($scaleFactor, $scaleFactor)
          $canvas.LayoutTransform = $scaleTransform

          # Define the circle path
          $circlePathData = "M 256,0 A 256,256 0 1,0 256,512 A 256,256 0 1,0 256,0"
          $circlePath = New-Object Windows.Shapes.Path
          $circlePath.Data = [Windows.Media.Geometry]::Parse($circlePathData)
          $circlePath.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#f41b43")

          # Define the exclamation mark path
          $exclamationPathData = "M 256 307.2 A 35.89 35.89 0 0 1 220.14 272.74 L 215.41 153.3 A 35.89 35.89 0 0 1 251.27 116 H 260.73 A 35.89 35.89 0 0 1 296.59 153.3 L 291.86 272.74 A 35.89 35.89 0 0 1 256 307.2 Z"
          $exclamationPath = New-Object Windows.Shapes.Path
          $exclamationPath.Data = [Windows.Media.Geometry]::Parse($exclamationPathData)
          $exclamationPath.Fill = [Windows.Media.Brushes]::White

          # Get the bounds of the exclamation mark path
          $exclamationBounds = $exclamationPath.Data.Bounds

          # Calculate the center position for the exclamation mark path
          $exclamationCenterX = ($canvas.Width - $exclamationBounds.Width) / 2 - $exclamationBounds.X
          $exclamationPath.SetValue([Windows.Controls.Canvas]::LeftProperty, $exclamationCenterX)

          # Define the rounded rectangle at the bottom (dot of exclamation mark)
          $roundedRectangle = New-Object Windows.Shapes.Rectangle
          $roundedRectangle.Width = 80
          $roundedRectangle.Height = 80
          $roundedRectangle.RadiusX = 30
          $roundedRectangle.RadiusY = 30
          $roundedRectangle.Fill = [Windows.Media.Brushes]::White

          # Calculate the center position for the rounded rectangle
          $centerX = ($canvas.Width - $roundedRectangle.Width) / 2
          $roundedRectangle.SetValue([Windows.Controls.Canvas]::LeftProperty, $centerX)
          $roundedRectangle.SetValue([Windows.Controls.Canvas]::TopProperty, 324.34)

          # Add the paths to the Canvas
          $canvas.Children.Add($circlePath) | Out-Null
          $canvas.Children.Add($exclamationPath) | Out-Null
          $canvas.Children.Add($roundedRectangle) | Out-Null
      }
      default {
          Write-Host "Invalid type: $type"
      }
  }

  # Add the Canvas to the Viewbox
  $LogoViewbox.Child = $canvas

  if ($render) {
      # Measure and arrange the canvas to ensure proper rendering
      $canvas.Measure([Windows.Size]::new($canvas.Width, $canvas.Height))
      $canvas.Arrange([Windows.Rect]::new(0, 0, $canvas.Width, $canvas.Height))
      $canvas.UpdateLayout()

      # Initialize RenderTargetBitmap correctly with dimensions
      $renderTargetBitmap = New-Object Windows.Media.Imaging.RenderTargetBitmap($canvas.Width, $canvas.Height, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)

      # Render the canvas to the bitmap
      $renderTargetBitmap.Render($canvas)

      # Create a BitmapFrame from the RenderTargetBitmap
      $bitmapFrame = [Windows.Media.Imaging.BitmapFrame]::Create($renderTargetBitmap)

      # Create a PngBitmapEncoder and add the frame
      $bitmapEncoder = [Windows.Media.Imaging.PngBitmapEncoder]::new()
      $bitmapEncoder.Frames.Add($bitmapFrame)

      # Save to a memory stream
      $imageStream = New-Object System.IO.MemoryStream
      $bitmapEncoder.Save($imageStream)
      $imageStream.Position = 0

      # Load the stream into a BitmapImage
      $bitmapImage = [Windows.Media.Imaging.BitmapImage]::new()
      $bitmapImage.BeginInit()
      $bitmapImage.StreamSource = $imageStream
      $bitmapImage.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
      $bitmapImage.EndInit()
      if ($bitmapImage.CanFreeze) {
          $bitmapImage.Freeze()
      }

      if ($null -ne $sync -and $sync.ContainsKey("RenderedAssetCache")) {
          $sync.RenderedAssetCache[$cacheKey] = $bitmapImage
      }

      return $bitmapImage
  } else {
      return $LogoViewbox
  }
}

function Invoke-WinUtilCloseRequest {
    <#
        .SYNOPSIS
            Asks what to do about work that is still running when the window is closed

        .DESCRIPTION
            A half finished install or tweak run is not ended without asking. Either it finishes
            without the window, reporting to the console and then exiting, or it is stopped and
            everything closes now.

        .PARAMETER RunningJob
            The name of the job in flight, so the question names what is at stake.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$RunningJob
    )

    # The question carries the meaning rather than naming buttons: Windows labels them in its own
    # language, so "Yes" in the text would not match a button reading "Ja".
    $answer = Show-WinUtilMessage -Button "YesNoCancel" -Icon "Warning" -Title "$RunningJob is still running" -Message @"
$RunningJob has not finished yet.

Close the window and let it finish in the console?

WinUtil will exit on its own once it is done. If you do not, it will be
stopped and everything closes now. Cancel keeps WinUtil open.
"@

    switch ("$answer") {
        "Yes" {
            Write-WinUtilLog -Component "UI" -Message "Close requested: closing the window, $RunningJob continues in the console."
            $sync.FinishInConsole = $true
            $sync.ForceClose = $true

            Write-Host ""
            Write-Host "WinUtil's window is closed. $RunningJob is still running here, and this window will close when it finishes." -ForegroundColor Cyan
            Write-Host ""

            # Posted rather than closed from inside the handler that is already unwinding
            Request-WinUtilWindowClose
        }
        "No" {
            Write-WinUtilLog -Component "UI" -Message "Close requested: stopping $RunningJob."
            Step-WinUtilJob -Status "Stopping $RunningJob" -State "Indeterminate"
            $sync.ForceClose = $true

            # Close the window first. The main thread owns pool shutdown after ShowDialog
            # returns, so the worker can finish its UI-dispatching finally block before the UI
            # runspace is disposed. Waiting for it here would deadlock the dispatcher.
            Request-WinUtilWindowClose
        }
        default {
            Write-WinUtilLog -Component "UI" -Message "Close cancelled, $RunningJob is still running."
        }
    }
}

function Request-WinUtilWindowClose {
    <#
        .SYNOPSIS
            Closes the window from outside the handler that is currently cancelling the close

    #>
    if (-not (Test-WinUtilUIAlive)) {
        return
    }

    $sync.Form.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [action]{
        $sync.Form.Close()
    }) | Out-Null
}

function Wait-WinUtilRemainingWork {
    <#
        .SYNOPSIS
            Waits for work that outlived the window, reporting to the console

        .DESCRIPTION
            Runs on the main thread once the interface has gone. The job is still on the worker
            pool and keeps logging, so this only waits and keeps the wait visible.

        .PARAMETER TimeoutMinutes
            Upper bound, so a worker that never returns cannot keep the process alive.
    #>
    param(
        # Double rather than int: an int silently truncates a fractional value to zero, which
        # turns the bound into "do not wait at all"
        [double]$TimeoutMinutes = 120
    )

    if (-not $sync.FinishInConsole -or -not $sync.ActiveJob) {
        return
    }

    $job = $sync.ActiveJob
    Write-WinUtilLog -Component "UI" -Message "Window closed, waiting for $job to finish."
    Write-Host "Waiting for $job to finish..." -ForegroundColor Cyan

    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sync.ActiveJob -and $clock.Elapsed.TotalMinutes -lt $TimeoutMinutes) {
        Start-Sleep -Milliseconds 250
    }

    # The job's last progress line is still open, so anything after it needs a fresh line
    Complete-WinUtilConsoleProgress

    if ($sync.ActiveJob) {
        Write-WinUtilLog -Level "WARN" -Component "UI" -Message "$job did not finish within $TimeoutMinutes minutes, exiting anyway."
        Write-Host "$job is taking longer than $TimeoutMinutes minutes. Exiting." -ForegroundColor Yellow
        return
    }

    Write-WinUtilLog -Component "UI" -Message "$job finished after the window closed, in $([int]$clock.Elapsed.TotalSeconds)s."
    Write-Host "$job finished. Closing." -ForegroundColor Green
}

Function Invoke-WinUtilCurrentSystem {

    <#

    .SYNOPSIS
        Checks which tweaks have already been applied.

    .EXAMPLE
        Invoke-WinUtilCurrentSystem -CheckBox "tweaks"

    #>

    param(
        $CheckBox,
        [switch]$BypassToggleStatusCache,
        [switch]$StopOnReadError
    )
    if ($CheckBox -eq "tweaks") {

        if (!(Test-Path 'HKU:\')) {$null = (New-PSDrive -PSProvider Registry -Name HKU -Root HKEY_USERS)}
        $readErrorAction = if ($StopOnReadError) { "Stop" } else { "SilentlyContinue" }

        $sync.configs.tweaks | Get-Member -MemberType NoteProperty | ForEach-Object {

            $Config = $psitem.Name
            $entry = $sync.configs.tweaks.$Config
            $registryKeys = $entry.registry
            $serviceKeys = $entry.service
            $entryType = $entry.Type

            if ($entry.ScheduledTaskCleanup) {
                # Legacy hidden bulk tweak is kept for old exports only. Do not
                # implicitly select it when an individual task was disabled.
                if ($entry.ParentGroup) { return }
                try {
                    if (Get-WinUtilTelemetryTaskStatus) { Write-Output $Config }
                } catch {
                    if ($StopOnReadError) { throw }
                    Write-WinUtilLog -Level 'WARN' -Component 'Tasks' -Message "Cannot inspect optional telemetry task state: $($_.Exception.Message)"
                }
                return
            }

            # Standalone driver tweaks have no registry/service table in the
            # catalog. An empty $values list is not proof that the driver was
            # disabled; consult the same state reader used by grouped toggles.
            if ($entry.driver -and $entryType -ne 'Toggle') {
                if ((Get-WinUtilOptionalDriverInfo -Name $entry.driver.Name).Disabled) {
                    Write-Output $Config
                }
                return
            }

            if (($registryKeys -or $serviceKeys -or $entry.driver -or $entry.scheduledTask) -and $entryType -ne "Combobox") {
                $Values = @()

                if ($entryType -eq "Toggle") {
                    if (-not (Get-WinUtilToggleStatus $Config `
                        -BypassCache:$BypassToggleStatusCache `
                        -StopOnReadError:$StopOnReadError)) {
                        $values += $False
                    }
                } else {
                    $registryMatchCount = 0
                    $registryTotal = 0

                    Foreach ($tweaks in $registryKeys) {
                        Foreach ($tweak in $tweaks) {
                            $registryTotal++
                            $regstate = $null

                            if (Test-Path $tweak.Path -ErrorAction $readErrorAction) {
                                if ($StopOnReadError) {
                                    $regstate = (Get-ItemProperty -Path $tweak.Path -ErrorAction Stop).$($tweak.Name)
                                } else {
                                    $regstate = Get-ItemProperty -Name $tweak.Name -Path $tweak.Path -ErrorAction SilentlyContinue | Select-Object -ExpandProperty $($tweak.Name)
                                }
                            }

                            if ($null -eq $regstate) {
                                switch ($tweak.DefaultState) {
                                    "true" {
                                        $regstate = $tweak.Value
                                    }
                                    "false" {
                                        $regstate = $tweak.OriginalValue
                                    }
                                    default {
                                        $regstate = $tweak.OriginalValue
                                    }
                                }
                            }

                            if ($regstate -eq $tweak.Value) {
                                $registryMatchCount++
                            }
                        }
                    }

                    if ($registryTotal -gt 0 -and $registryMatchCount -ne $registryTotal) {
                        $values += $False
                    }
                }

                Foreach ($tweaks in $serviceKeys) {
                    Foreach ($tweak in $tweaks) {
                        try {
                            $Service = Get-Service -Name $tweak.Name -ErrorAction $readErrorAction
                        } catch {
                            if ($StopOnReadError -and $_.FullyQualifiedErrorId -like "NoServiceFoundForGivenName*") {
                                # A removed optional service means this tweak is not applied; it does
                                # not make the registry and service state for every other tweak unknown.
                                $values += $False
                                continue
                            }
                            throw
                        }

                        if ($Service) {
                            $actualValue = $Service.StartType
                            $expectedValue = $tweak.StartupType
                            if ($expectedValue -ne $actualValue) {
                                $values += $False
                            }
                        } elseif ($StopOnReadError) {
                            $values += $False
                        }
                    }
                }

                if ($values -notcontains $false) {
                    Write-Output $Config
                }
            }
        }
    }
}

function Invoke-WinUtilExplorerUpdate {
     <#
    .SYNOPSIS
        Refreshes the Windows Explorer
    #>
    param (
        [string]$action = "refresh"
    )

    if ($action -eq "refresh") {
        # The handle is of no use to the caller, and leaving it in the pipeline puts it into
        # whatever result the calling workflow returns
        $null = Invoke-WPFRunspace -ScriptBlock {
            # Define the Win32 type only if it doesn't exist
            if (-not ([System.Management.Automation.PSTypeName]'Win32').Type) {
                Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class Win32 {
    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = false)]
    public static extern IntPtr SendMessageTimeout(
        IntPtr hWnd, uint Msg, IntPtr wParam, string lParam,
        uint fuFlags, uint uTimeout, out IntPtr lpdwResult);
}
"@
            }

            $HWND_BROADCAST = [IntPtr]0xffff
            $WM_SETTINGCHANGE = 0x1A
            $SMTO_ABORTIFHUNG = 0x2

            [Win32]::SendMessageTimeout($HWND_BROADCAST, $WM_SETTINGCHANGE,
                [IntPtr]::Zero, "ImmersiveColorSet", $SMTO_ABORTIFHUNG, 100,
                [ref]([IntPtr]::Zero))
        }
    } elseif ($action -eq "restart") {
        taskkill.exe /F /IM "explorer.exe"
        Start-Process "explorer.exe"
    }
}

function Invoke-WinUtilFontScaling {
    <#

    .SYNOPSIS
        Applies UI and font scaling for accessibility

    .PARAMETER ScaleFactor
        Sets the scaling from 0.75 and 2.0.
        Default is 1.0 (100% - no scaling)

    .EXAMPLE
        Invoke-WinUtilFontScaling -ScaleFactor 1.25
        # Applies 125% scaling
    #>

    param (
        [double]$ScaleFactor = 1.0
    )

    # Validate if scale factor is within the range
    if ($ScaleFactor -lt 0.75 -or $ScaleFactor -gt 2.0) {
        Write-Warning "Scale factor must be between 0.75 and 2.0. Using 1.0 instead."
        $ScaleFactor = 1.0
    }

    # Define an array for resources to be scaled
    $fontResources = @(
        # Fonts
        "FontSize",
        "ButtonFontSize",
        "HeaderFontSize",
        "Win11StepTitleFontSize",
        "Win11StepHeroFontSize",
        "TabButtonFontSize",
        "ConfigTabButtonFontSize",
        "IconFontSize",
        "SettingsIconFontSize",
        "CloseIconFontSize",
        "AppEntryFontSize",
        "SearchBarTextBoxFontSize",
        "SearchBarClearButtonFontSize",
        "CustomDialogFontSize",
        "CustomDialogFontSizeHeader",
        "ConfigUpdateButtonFontSize",
        # Buttons and UI
        "CheckBoxBulletDecoratorSize",
        "ButtonWidth",
        "ButtonHeight",
        "TabButtonWidth",
        "TabButtonHeight",
        "IconButtonSize",
        "AppEntryWidth",
        "SearchBarWidth",
        "SearchBarHeight",
        "CustomDialogWidth",
        "CustomDialogHeight",
        "CustomDialogLogoSize",
        "ToolTipWidth"
    )

    # Apply scaling to each resource
    foreach ($resourceName in $fontResources) {
        try {
            # Get the default font size from the theme configuration
            $originalValue = $sync.configs.themes.shared.$resourceName
            if ($originalValue) {
                # Convert string to double since values are stored as strings
                $originalValue = [double]$originalValue
                # Calculates and applies the new font size
                $newValue = [math]::Round($originalValue * $ScaleFactor, 1)
                $sync.Form.Resources[$resourceName] = $newValue
            }
        }
        catch {
            Write-Warning "Failed to scale resource $resourceName : $_"
        }
    }

    # Store the scale factor so it can be reapplied after theme changes
    $sync.FontScaleFactor = $ScaleFactor

    # Update the font scaling percentage displayed on the UI
    if ($sync.FontScalingValue) {
        $percentage = [math]::Round($ScaleFactor * 100)
        $sync.FontScalingValue.Text = "$percentage%"
    }
}

function Get-WinUtilGuidedLanguage {
    # The guided window is always in Spanish, whatever language the main
    # window uses. guided.json keeps English as the fallback text.
    return 'es'
}

function Get-WinUtilGuidedText {
    param($Text)
    if ($null -eq $Text) { return '' }
    $language = Get-WinUtilGuidedLanguage
    $value = if ($Text.PSObject.Properties[$language]) { $Text.$language } else { $Text.en }
    return Convert-WinUtilTextEncoding -Text ([string]$value)
}

function Get-WinUtilGuidedList {
    # Same as Get-WinUtilGuidedText, for { en: [...], es: [...] } lists.
    param($List)
    if ($null -eq $List) { return @() }
    $language = Get-WinUtilGuidedLanguage
    $values = if ($List.PSObject.Properties[$language]) { $List.$language } else { $List.en }
    return @($values | ForEach-Object { Convert-WinUtilTextEncoding -Text ([string]$_) })
}

function Get-WinUtilGuidedQuestions {
    return @($sync.configs.guided.Questions)
}

function Get-WinUtilGuidedGroupMembers {
    # Only installed services: missing ones are hidden in the Tweaks tab too.
    param([Parameter(Mandatory)][string]$GroupKey)
    return @($sync.configs.tweaks.$GroupKey.Children | Where-Object {
        $child = $sync.configs.tweaks.$_
        $child.service -and (Get-Service -Name $child.service[0].Name -ErrorAction SilentlyContinue)
    })
}

function Get-WinUtilGuidedPlan {
    <#
        .SYNOPSIS
            Turns guided answers into the work Apply runs and the rows the summary shows
    #>
    param(
        [hashtable]$Answers = @{},
        [hashtable]$Options = @{}
    )

    $tweaks = [System.Collections.Generic.List[string]]::new()
    $toggles = [System.Collections.Generic.List[object]]::new()
    $groupChanges = [System.Collections.Generic.List[object]]::new()
    $taskChanges = [System.Collections.Generic.List[object]]::new()
    $items = [System.Collections.Generic.List[object]]::new()
    $restorePoint = $false
    $powerPlan = $false
    $reboot = $false

    $questions = @(Get-WinUtilGuidedQuestions)
    for ($index = 0; $index -lt $questions.Count; $index++) {
        $question = $questions[$index]
        if (-not $Answers[$question.Id]) { continue }

        # A question with options contributes one summary row per selected option.
        $parts = @(if ($question.Options) {
            $chosen = $Options[$question.Id]
            $question.Options | Where-Object { $chosen -and $chosen[$_.Id] } | ForEach-Object {
                [pscustomobject]@{ Label = Get-WinUtilGuidedText $_.Label; Actions = @($_.Actions) }
            }
        } else {
            [pscustomobject]@{ Label = Get-WinUtilGuidedText $question.Summary; Actions = @($question.Actions) }
        })

        foreach ($part in $parts) {
            foreach ($action in $part.Actions) {
                $key = [string]$action.Key
                $entry = $sync.configs.tweaks.$key
                if ($null -eq $entry) { throw "Guided question '$($question.Id)' names unknown entry '$key'." }
                if ($key -eq 'WPFTweaksRestorePoint') {
                    $restorePoint = $true
                } elseif ($entry.Type -eq 'Button') {
                    # Buttons run code, not catalog entries; only this one is supported.
                    if ($key -ne 'WPFAddUltPerf') { throw "Guided question '$($question.Id)' names button '$key', which guided mode cannot run." }
                    $powerPlan = $true
                } elseif ($entry.Type -eq 'ServiceGroup') {
                    foreach ($member in @(Get-WinUtilGuidedGroupMembers -GroupKey $key)) {
                        if (-not ($groupChanges | Where-Object { $_.Key -eq $member })) {
                            $groupChanges.Add([pscustomobject]@{ Key = [string]$member; Disable = $true })
                        }
                    }
                } elseif ($entry.Type -eq 'TaskGroup') {
                    # Members narrows the group to telemetry tasks; the Apply job
                    # skips tasks this PC does not have.
                    $members = if ($action.Members) { @($action.Members) } else { @($entry.Children) }
                    foreach ($member in $members) {
                        if ($member -notin @($entry.Children)) { throw "Guided question '$($question.Id)' names '$member', which is not part of '$key'." }
                        if (-not ($taskChanges | Where-Object { $_.Key -eq $member })) {
                            $taskChanges.Add([pscustomobject]@{ Key = [string]$member; Disable = $true })
                        }
                    }
                } elseif ($entry.Type -eq 'Toggle') {
                    $toggles.Add([pscustomobject]@{ Key = $key; State = [bool]$action.State })
                } elseif (-not $tweaks.Contains($key)) {
                    $tweaks.Add($key)
                }
            }
            $items.Add([pscustomobject]@{
                Index = $index
                Category = Get-WinUtilGuidedText $question.Category
                Label = $part.Label
                Advanced = ($question.Section -eq 'advanced')
                Reversible = ($question.Reversible -ne $false)
                Reboot = [bool]$question.Reboot
            })
        }
        if ($question.Reboot -and $parts.Count -gt 0) { $reboot = $true }
    }

    return [pscustomobject]@{
        RestorePoint = $restorePoint
        PowerPlan = $powerPlan
        Tweaks = @($tweaks)
        Toggles = @($toggles)
        GroupChanges = @($groupChanges)
        TaskChanges = @($taskChanges)
        Reboot = $reboot
        Items = @($items)
    }
}

function Get-WinUtilCpuMitigationAdvice {
    <#
        .SYNOPSIS
            Estimates from the CPU model whether turning off Spectre/Meltdown mitigations pays off

        .DESCRIPTION
            Intel CPUs before the 9th generation need software mitigations for Meltdown and
            Spectre v2, which cost the most. Intel 10th generation and later and AMD Zen 2 and
            later fix most of this in hardware, so the gain is small. Name-based estimate only.
    #>
    param([string]$Name)
    if (-not $Name) {
        try { $Name = [string](Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop | Select-Object -First 1).Name } catch { $Name = '' }
    }
    $Name = ($Name -replace '\s+', ' ').Trim()

    $verdict = 'Unknown'
    if ($Name -match 'Intel') {
        if ($Name -match 'Core\(TM\) Ultra|Core Ultra') {
            $verdict = 'Low'
        } elseif ($Name -match '\bi[3579]-(\d{3,5})') {
            # 4-digit models starting with 1 are 10th/11th/12th+ gen laptop chips (i7-1165G7).
            $model = $Matches[1]
            $generation = if ($model.Length -eq 3) { 1 } elseif ($model.StartsWith('1')) { [int]$model.Substring(0, 2) } else { [int]$model.Substring(0, 1) }
            $verdict = if ($generation -le 8) { 'High' } elseif ($generation -eq 9) { 'Medium' } else { 'Low' }
        } elseif ($Name -match 'Core\(TM\)2|Core 2') {
            $verdict = 'High'
        }
    } elseif ($Name -match 'AMD') {
        if ($Name -match 'Ryzen AI') {
            $verdict = 'Low'
        } elseif ($Name -match 'Ryzen.*?\b(\d)\d{3}([A-Z]*)') {
            # Ryzen 1000/2000 and 3000 APUs (3400G) are Zen/Zen+.
            $series = [int]$Matches[1]
            $verdict = if ($series -le 2 -or ($series -eq 3 -and $Matches[2] -like 'G*')) { 'Medium' } else { 'Low' }
        } elseif ($Name -match '\bFX\b|Athlon|Phenom|\bA\d+-\d') {
            $verdict = 'Medium'
        }
    }

    $text = switch ($verdict) {
        'High' { @{ Title = 'Puede valer la pena en tu procesador'; Color = '#3FA34D'
                Text = 'Es un Intel anterior a la 9.ª generación: depende de mitigaciones por software que pueden costar bastante rendimiento en juegos, disco y red.' } }
        'Medium' { @{ Title = 'Ganancia pequeña en tu procesador'; Color = '#D4A017'
                Text = 'Tu procesador tiene parte de estas protecciones en hardware. Pruébalo solo si buscas cada FPS y aceptas el riesgo.' } }
        'Low' { @{ Title = 'No recomendado en tu procesador'; Color = '#E07B24'
                Text = 'Tu procesador trae estas protecciones en hardware: la ganancia es mínima y pierdes seguridad.' } }
        default { @{ Title = 'No se pudo identificar la generación de tu procesador'; Color = '#8A8A8A'
                Text = 'La ganancia suele ser notable en Intel anteriores a la 9.ª generación y mínima en procesadores modernos.' } }
    }
    return [pscustomobject]@{
        Name = $Name
        Verdict = $verdict
        Title = $text.Title
        Text = $text.Text
        Color = $text.Color
    }
}

function Get-WinUtilPowerPlanAdvice {
    <#
        .SYNOPSIS
            Says whether the Ultimate Performance plan suits this PC: desktop yes, laptop no

        .DESCRIPTION
            The chassis type decides. A battery only counts when the chassis is unknown,
            because a USB UPS also shows up as a battery on desktops.
    #>
    param([int[]]$ChassisTypes, [object]$HasBattery = $null)
    if (-not $PSBoundParameters.ContainsKey('ChassisTypes')) {
        try { $ChassisTypes = @((Get-CimInstance -ClassName Win32_SystemEnclosure -ErrorAction Stop).ChassisTypes) } catch { $ChassisTypes = @() }
    }
    $portable = @(8, 9, 10, 11, 12, 14, 18, 21, 30, 31, 32)
    $desktop = @(3, 4, 5, 6, 7, 13, 15, 16, 17, 23, 24, 35, 36)
    $isLaptop = if (@($ChassisTypes | Where-Object { $_ -in $portable }).Count -gt 0) { $true }
        elseif (@($ChassisTypes | Where-Object { $_ -in $desktop }).Count -gt 0) { $false }
        else {
            if ($null -eq $HasBattery) {
                try { $HasBattery = @(Get-CimInstance -ClassName Win32_Battery -ErrorAction Stop).Count -gt 0 } catch { $HasBattery = $false }
            }
            [bool]$HasBattery
        }

    if ($isLaptop) {
        return [pscustomobject]@{
            Recommend = $false
            Title = 'No recomendado en tu equipo (portátil)'
            Text = 'Tu equipo es portátil: el plan sube el consumo y la temperatura y gasta más batería. Aunque la uses enchufada, la ganancia suele ser pequeña.'
            Color = '#E07B24'
        }
    }
    return [pscustomobject]@{
        Recommend = $true
        Title = 'Recomendado en tu equipo (PC de escritorio)'
        Text = 'Tu equipo es de escritorio: no tienes batería que cuidar. Solo sube un poco el consumo en reposo.'
        Color = '#3FA34D'
    }
}

function Test-WinUtilGuidedQuestionApplied {
    # True only when every action is a readable toggle or service group already
    # in the answer's state. Script tweaks have no reliable state, so $null.
    param([Parameter(Mandatory)]$Question)
    if ($Question.Options -or -not $Question.Actions) { return $null }
    foreach ($action in @($Question.Actions)) {
        $entry = $sync.configs.tweaks.$($action.Key)
        if ($entry.Type -eq 'ServiceGroup') {
            foreach ($member in @(Get-WinUtilGuidedGroupMembers -GroupKey $action.Key)) {
                if (-not (Get-WinUtilToggleStatus -ToggleSwitch $member)) { return $false }
            }
        } elseif ($entry.Type -eq 'Toggle' -and $null -ne $action.State) {
            if ([bool](Get-WinUtilToggleStatus -ToggleSwitch $action.Key) -ne [bool]$action.State) { return $false }
        } else {
            return $null
        }
    }
    return $true
}

function New-WinUtilGuidedBadge {
    param([string]$Text, [string]$Color)
    $brush = [Windows.Media.BrushConverter]::new().ConvertFromString($Color)
    $badge = New-Object Windows.Controls.Border
    $badge.BorderBrush = $brush
    $badge.BorderThickness = '1.5'
    $badge.CornerRadius = '10'
    $badge.Padding = '10,3'
    $badge.Margin = '0,0,8,6'
    $label = New-Object Windows.Controls.TextBlock
    $label.Text = $Text
    $label.FontSize = 12
    $label.FontWeight = 'Bold'
    $label.Background = [Windows.Media.Brushes]::Transparent
    $label.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, 'MainForegroundColor')
    $badge.Child = $label
    return $badge
}

function New-WinUtilGuidedWindow {
    <#
        .SYNOPSIS
            Builds the separate guided-mode window from $guidedXML

        .DESCRIPTION
            A closed WPF window cannot be shown again, so every opening builds a new one. The
            main window's resources are merged in, which gives it the same theme and styles.
    #>
    param([System.Windows.Window]$Owner)

    [xml]$xaml = $guidedXML
    $window = [Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new($xaml))
    if ($sync.Form) { $window.Resources.MergedDictionaries.Add($sync.Form.Resources) }
    $xaml.SelectNodes('//*[@Name]') | ForEach-Object { $sync[$_.Name] = $window.FindName($_.Name) }
    $sync.GuidedWindow = $window
    $sync.GuidedOpenAdvanced = $false
    if ($Owner) {
        $window.Owner = $Owner
        $window.WindowStartupLocation = 'CenterOwner'
    }
    if ($sync.version) { $window.Title = "APBOptimizer $($sync.version)" }

    # The main window wired its buttons before this one existed.
    foreach ($node in $xaml.SelectNodes("//*[local-name()='Button'][@Name]")) {
        $sync[$node.Name].Add_Click({ Invoke-WPFButton $this.Name })
    }
    $sync.WPFGuidedTitleBar.Add_MouseLeftButtonDown({ $sync.GuidedWindow.DragMove() })
    $window.Add_Closing({
        param($eventSender, $closingArgs)
        $null = $eventSender
        if ($sync.ActiveJob -eq 'Guided') {
            $closingArgs.Cancel = $true
            $message = if ((Get-WinUtilGuidedLanguage) -eq 'es') { 'Espera a que terminen de aplicarse los cambios.' } else { 'Wait until the changes finish applying.' }
            Show-WinUtilMessage -Title 'APBOptimizer' -Message $message -Button 'OK' -Icon 'Information' | Out-Null
        }
    })
    $window.Add_Closed({ $sync.GuidedPanel = $null })

    try { $sync.GuidedLogoPanel.Children.Add((Invoke-WinUtilAssets -Type 'logo' -Size 25)) | Out-Null } catch {
        Write-WinUtilLog -Level 'WARN' -Component 'Guided' -Message "Could not draw the guided window logo: $($_.Exception.Message)"
    }
    return $window
}

function Show-WinUtilGuidedWindow {
    <#
        .SYNOPSIS
            Shows the guided window until it closes; returns $true when the user chose advanced mode
    #>
    param(
        [ValidateSet('Chooser', 'Resume')][string]$Start = 'Chooser',
        [System.Windows.Window]$Owner
    )

    $sync.GuidedReviewPlan = $null
    $window = New-WinUtilGuidedWindow -Owner $Owner
    switch ($Start) {
        'Chooser' { Show-WinUtilModeChooser }
        'Resume' {
            # Reopening keeps an unfinished run's answers.
            if ($sync.GuidedState -and -not $sync.GuidedState.Completed) {
                Show-WinUtilGuidedQuestion -Index $sync.GuidedState.Index
            } else {
                Start-WinUtilGuided
            }
        }
    }
    $null = $window.ShowDialog()
    $sync.GuidedWindow = $null
    return [bool]$sync.GuidedOpenAdvanced
}

function Show-WinUtilGuidedPanel {
    param([Parameter(Mandatory)][ValidateSet('Chooser', 'Wizard', 'Summary', 'Done')][string]$Panel)
    $panels = @{ Chooser = 'WPFModeChooser'; Wizard = 'WPFGuidedWizard'; Summary = 'WPFGuidedSummary'; Done = 'WPFGuidedDone' }
    foreach ($entry in $panels.GetEnumerator()) {
        $sync[$entry.Value].Visibility = if ($entry.Key -eq $Panel) { 'Visible' } else { 'Collapsed' }
    }
    $sync.GuidedPanel = $Panel
}

function Show-WinUtilModeChooser {
    Show-WinUtilGuidedPanel -Panel 'Chooser'
}

function Select-WinUtilMode {
    param([Parameter(Mandatory)][ValidateSet('guided', 'advanced')][string]$Mode)
    if ($Mode -eq 'guided') { Start-WinUtilGuided } else { Exit-WinUtilGuided }
}

function Start-WinUtilGuided {
    $sync.GuidedState = @{ Index = 0; Answers = @{}; Options = @{}; ReturnToSummary = $false; Completed = $false }
    Show-WinUtilGuidedQuestion -Index 0
}

function Exit-WinUtilGuided {
    # Closing hands over to the full interface: Start-WinUtilUserInterface opens it,
    # or it is already open underneath when guided mode came from its menu.
    $sync.GuidedOpenAdvanced = $true
    if ($sync.GuidedWindow) { $sync.GuidedWindow.Close() }
}

function Show-WinUtilGuidedQuestion {
    param([int]$Index)

    $questions = @(Get-WinUtilGuidedQuestions)
    if ($Index -ge $questions.Count) {
        Show-WinUtilGuidedSummary
        return
    }
    if ($Index -lt 0) { $Index = 0 }
    $sync.GuidedState.Index = $Index
    $question = $questions[$Index]
    $isSpanish = ((Get-WinUtilGuidedLanguage) -eq 'es')
    $basicCount = @($questions | Where-Object { $_.Section -ne 'advanced' }).Count
    $advancedCount = $questions.Count - $basicCount

    $sync.WPFGuidedCategory.Text = Get-WinUtilGuidedText $question.Category
    $sync.WPFGuidedStep.Text = if ($question.Section -eq 'advanced') {
        $position = $Index - $basicCount + 1
        if ($isSpanish) { "Avanzado $position de $advancedCount" } else { "Advanced $position of $advancedCount" }
    } elseif ($isSpanish) { "Pregunta $($Index + 1) de $basicCount" } else { "Question $($Index + 1) of $basicCount" }
    $sync.WPFGuidedProgress.Value = [math]::Round((($Index + 1) / $questions.Count) * 100)
    $sync.WPFGuidedTitle.Text = Get-WinUtilGuidedText $question.Title
    $sync.WPFGuidedBody.Text = Get-WinUtilGuidedText $question.Body
    $sync.WPFGuidedDetailsList.Children.Clear()
    $details = @(Get-WinUtilGuidedList $question.Details)
    foreach ($detail in $details) {
        $line = New-Object Windows.Controls.TextBlock
        $line.Text = [string][char]0x2022 + '  ' + $detail
        $line.FontSize = 14
        $line.TextWrapping = 'Wrap'
        $line.Margin = '4,0,0,4'
        $line.Opacity = 0.9
        $line.Background = [Windows.Media.Brushes]::Transparent
        $line.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, 'MainForegroundColor')
        $sync.WPFGuidedDetailsList.Children.Add($line) | Out-Null
    }
    $sync.WPFGuidedDetails.Visibility = if ($details.Count -gt 0) { 'Visible' } else { 'Collapsed' }
    $note = Get-WinUtilGuidedText $question.Note
    $sync.WPFGuidedNoteText.Text = $note
    $sync.WPFGuidedNote.Visibility = if ($note) { 'Visible' } else { 'Collapsed' }

    # Some answers depend on this PC: the advice box says why, and a desktop
    # makes the power plan a recommended answer.
    $advice = $null
    if ($question.Advice -eq 'CPUMitigations') {
        if (-not $sync.GuidedCpuAdvice) { $sync.GuidedCpuAdvice = Get-WinUtilCpuMitigationAdvice }
        $cpu = $sync.GuidedCpuAdvice
        $cpuName = if ($cpu.Name) { $cpu.Name } else { 'desconocido' }
        $advice = [pscustomobject]@{ Title = "$($cpu.Title) ($cpuName)"; Text = "$($cpu.Text) Estimación según el modelo del procesador."; Color = $cpu.Color; Recommend = $false }
    } elseif ($question.Advice -eq 'PowerPlan') {
        if (-not $sync.GuidedPowerAdvice) { $sync.GuidedPowerAdvice = Get-WinUtilPowerPlanAdvice }
        $advice = $sync.GuidedPowerAdvice
    }
    $recommended = [bool]$question.Recommended -or ($null -ne $advice -and [bool]$advice.Recommend)

    $sync.WPFGuidedBadges.Children.Clear()
    if ($question.Section -eq 'advanced') {
        $sync.WPFGuidedBadges.Children.Add((New-WinUtilGuidedBadge -Text $(if ($isSpanish) { 'Avanzado' } else { 'Advanced' }) -Color '#E07B24')) | Out-Null
    } elseif ($recommended) {
        $sync.WPFGuidedBadges.Children.Add((New-WinUtilGuidedBadge -Text $(if ($isSpanish) { 'Recomendado' } else { 'Recommended' }) -Color '#2E77FF')) | Out-Null
    }
    if ($question.Reversible -eq $false) {
        $sync.WPFGuidedBadges.Children.Add((New-WinUtilGuidedBadge -Text $(if ($isSpanish) { 'No se puede deshacer' } else { 'Cannot be undone' }) -Color '#E07B24')) | Out-Null
    } else {
        $sync.WPFGuidedBadges.Children.Add((New-WinUtilGuidedBadge -Text $(if ($isSpanish) { 'Se puede deshacer' } else { 'Can be undone' }) -Color '#3FA34D')) | Out-Null
    }
    if ($question.Reboot) {
        $sync.WPFGuidedBadges.Children.Add((New-WinUtilGuidedBadge -Text $(if ($isSpanish) { 'Requiere reiniciar' } else { 'Restart required' }) -Color '#D4A017')) | Out-Null
    }

    $sync.WPFGuidedAdvice.Visibility = 'Collapsed'
    if ($advice) {
        $sync.WPFGuidedAdviceTitle.Text = Convert-WinUtilTextEncoding -Text ([string]$advice.Title)
        $sync.WPFGuidedAdviceText.Text = Convert-WinUtilTextEncoding -Text ([string]$advice.Text)
        $sync.WPFGuidedAdvice.BorderBrush = [Windows.Media.BrushConverter]::new().ConvertFromString($advice.Color)
        $sync.WPFGuidedAdvice.Visibility = 'Visible'
    }

    $applied = $null
    try { $applied = Test-WinUtilGuidedQuestionApplied -Question $question } catch { $applied = $null }
    $sync.WPFGuidedState.Text = if ($isSpanish) { 'Ya está así en tu PC.' } else { 'This PC is already set this way.' }
    $sync.WPFGuidedState.Visibility = if ($applied -eq $true) { 'Visible' } else { 'Collapsed' }

    $sync.WPFGuidedOptions.Children.Clear()
    $sync.GuidedOptionBoxes = [System.Collections.Generic.List[object]]::new()
    if ($question.Options) {
        $saved = $sync.GuidedState.Options[$question.Id]
        $asToggles = ($question.OptionStyle -eq 'Toggle')
        foreach ($option in @($question.Options)) {
            $box = New-Object Windows.Controls.CheckBox
            $box.Tag = [string]$option.Id
            $box.IsChecked = if ($saved -and $saved.ContainsKey([string]$option.Id)) { [bool]$saved[[string]$option.Id] } else { [bool]$option.Default }
            $content = New-Object Windows.Controls.StackPanel
            foreach ($line in @(
                @{ Text = Get-WinUtilGuidedText $option.Label; Size = 15; Bold = $true },
                @{ Text = Get-WinUtilGuidedText $option.Detail; Size = 13; Bold = $false }
            )) {
                $text = New-Object Windows.Controls.TextBlock
                $text.Text = $line.Text
                $text.FontSize = $line.Size
                $text.TextWrapping = 'Wrap'
                $text.Background = [Windows.Media.Brushes]::Transparent
                if ($line.Bold) { $text.FontWeight = 'Bold' } else { $text.Opacity = 0.8; $text.Margin = '0,3,0,0' }
                $text.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, 'MainForegroundColor')
                $content.Children.Add($text) | Out-Null
            }
            $sync.GuidedOptionBoxes.Add($box)

            if (-not $asToggles) {
                $box.Margin = '0,0,0,10'
                $box.Content = $content
                $sync.WPFGuidedOptions.Children.Add($box) | Out-Null
                continue
            }

            # Settings-style row: text on the left, the same switch the Tweaks tab
            # uses on the right. Clicking anywhere on the row flips it.
            $box.SetResourceReference([Windows.FrameworkElement]::StyleProperty, 'ColorfulToggleSwitchStyle')
            $box.VerticalAlignment = 'Center'
            $box.Margin = '20,0,0,0'
            $box.IsHitTestVisible = $false
            [System.Windows.Automation.AutomationProperties]::SetName($box, (Get-WinUtilGuidedText $option.Label))
            $grid = New-Object Windows.Controls.Grid
            foreach ($width in @('*', 'Auto')) {
                $column = New-Object Windows.Controls.ColumnDefinition
                $column.Width = $width
                $grid.ColumnDefinitions.Add($column) | Out-Null
            }
            [Windows.Controls.Grid]::SetColumn($box, 1)
            $grid.Children.Add($content) | Out-Null
            $grid.Children.Add($box) | Out-Null
            $row = New-Object Windows.Controls.Border
            $row.Child = $grid
            $row.Tag = $box
            $row.Padding = '16,12'
            $row.Margin = '0,0,0,10'
            $row.CornerRadius = '6'
            $row.BorderThickness = '1'
            $row.Cursor = [Windows.Input.Cursors]::Hand
            $row.SetResourceReference([Windows.Controls.Border]::BackgroundProperty, 'TweakHelpSectionColor')
            $row.SetResourceReference([Windows.Controls.Border]::BorderBrushProperty, 'TweakHelpBorderColor')
            $row.Add_MouseLeftButtonUp({ $this.Tag.IsChecked = -not [bool]$this.Tag.IsChecked })
            $sync.WPFGuidedOptions.Children.Add($row) | Out-Null
        }
    }

    $yes = Get-WinUtilGuidedText $question.YesLabel
    $no = Get-WinUtilGuidedText $question.NoLabel
    $sync.WPFGuidedYes.Content = if ($yes) { $yes } elseif ($isSpanish) { 'Sí' } else { 'Yes' }
    $sync.WPFGuidedNo.Content = if ($no) { $no } else { 'No' }
    # Advanced questions highlight neither answer. ClearValue restores the
    # window's implicit Button style; assigning $null would fall back to the
    # system theme.
    if ($recommended) {
        $sync.WPFGuidedYes.Style = $sync.Form.FindResource('GuidedPrimaryButton')
    } else {
        $sync.WPFGuidedYes.ClearValue([Windows.FrameworkElement]::StyleProperty)
    }
    $sync.WPFGuidedBack.Content = if ($isSpanish) { 'Atrás' } else { 'Back' }

    Show-WinUtilGuidedPanel -Panel 'Wizard'
}

function Save-WinUtilGuidedOptions {
    # Keeps the current checkbox choices when the view is redrawn.
    param([bool]$Answer = $true)
    $questions = @(Get-WinUtilGuidedQuestions)
    $question = $questions[$sync.GuidedState.Index]
    if (-not $question.Options) { return $null }
    $selected = @{}
    foreach ($box in @($sync.GuidedOptionBoxes)) {
        $selected[[string]$box.Tag] = ($Answer -and $box.IsChecked -eq $true)
    }
    $sync.GuidedState.Options[$question.Id] = $selected
    return $selected
}

function Submit-WinUtilGuidedAnswer {
    param([Parameter(Mandatory)][bool]$Answer)
    $questions = @(Get-WinUtilGuidedQuestions)
    $question = $questions[$sync.GuidedState.Index]
    $selected = Save-WinUtilGuidedOptions -Answer $Answer
    $sync.GuidedState.Answers[$question.Id] = if ($question.Options) { [bool](@($selected.Values) -contains $true) } else { $Answer }

    if ($sync.GuidedState.ReturnToSummary) {
        $sync.GuidedState.ReturnToSummary = $false
        Show-WinUtilGuidedSummary
        return
    }
    Show-WinUtilGuidedQuestion -Index ($sync.GuidedState.Index + 1)
}

function Step-WinUtilGuidedBack {
    if ($sync.GuidedState.ReturnToSummary) {
        $sync.GuidedState.ReturnToSummary = $false
        Show-WinUtilGuidedSummary
    } elseif ($sync.GuidedState.Index -le 0) {
        Show-WinUtilModeChooser
    } else {
        Show-WinUtilGuidedQuestion -Index ($sync.GuidedState.Index - 1)
    }
}

function Show-WinUtilGuidedSummary {
    $isSpanish = ((Get-WinUtilGuidedLanguage) -eq 'es')
    $plan = Get-WinUtilGuidedPlan -Answers $sync.GuidedState.Answers -Options $sync.GuidedState.Options
    $sync.GuidedPlan = $plan
    $sync.GuidedState.Index = @(Get-WinUtilGuidedQuestions).Count
    $count = @($plan.Items).Count

    $sync.WPFGuidedSummaryTitle.Text = if ($count -eq 0) {
        if ($isSpanish) { 'No hay cambios para aplicar' } else { 'There are no changes to apply' }
    } elseif ($isSpanish) { "Se aplicarán $count cambios" } else { "$count changes will be applied" }
    $sync.WPFGuidedSummarySubtitle.Text = if ($isSpanish) {
        'Lo que respondiste con No no se toca. Pulsa Cambiar para corregir una respuesta.'
    } else { 'Anything you answered No to is left alone. Click Change to correct an answer.' }
    $sync.WPFGuidedSummaryNote.Text = if (@($plan.Items | Where-Object { -not $_.Reversible }).Count -gt 0) {
        if ($isSpanish) { 'Los cambios marcados "No se puede deshacer" no vuelven atrás. El resto se puede revertir desde el modo avanzado.' }
        else { 'Changes marked "Cannot be undone" cannot be reverted. Everything else can be reverted from advanced mode.' }
    } elseif ($isSpanish) { 'Todo se puede revertir después desde el modo avanzado.' } else { 'Everything can be reverted later from advanced mode.' }

    $list = $sync.WPFGuidedSummaryList
    $list.Children.Clear()
    $row = 0
    foreach ($item in @($plan.Items)) {
        $grid = New-Object Windows.Controls.Grid
        $grid.Margin = '0'
        foreach ($width in @('170', '*', 'Auto', 'Auto')) {
            $column = New-Object Windows.Controls.ColumnDefinition
            $column.Width = $width
            $grid.ColumnDefinitions.Add($column) | Out-Null
        }
        if ($row % 2 -eq 0) { $grid.SetResourceReference([Windows.Controls.Panel]::BackgroundProperty, 'TweakHelpSectionColor') }

        $category = New-Object Windows.Controls.TextBlock
        $category.Text = $item.Category
        $category.FontWeight = 'SemiBold'
        $category.Margin = '14,9,8,9'
        $category.VerticalAlignment = 'Center'
        $category.Background = [Windows.Media.Brushes]::Transparent
        $category.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, $(if ($item.Advanced) { 'ProgressBarWarningColor' } else { 'LinkForegroundColor' }))
        [Windows.Controls.Grid]::SetColumn($category, 0)

        $label = New-Object Windows.Controls.TextBlock
        $label.Text = $item.Label
        $label.FontSize = 14
        $label.TextWrapping = 'Wrap'
        $label.Margin = '0,9,8,9'
        $label.VerticalAlignment = 'Center'
        $label.Background = [Windows.Media.Brushes]::Transparent
        $label.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, 'MainForegroundColor')
        [Windows.Controls.Grid]::SetColumn($label, 1)

        $tags = New-Object Windows.Controls.WrapPanel
        $tags.VerticalAlignment = 'Center'
        $tags.Margin = '0,6,0,0'
        if ($item.Reboot) { $tags.Children.Add((New-WinUtilGuidedBadge -Text $(if ($isSpanish) { 'Reinicio' } else { 'Restart' }) -Color '#D4A017')) | Out-Null }
        if (-not $item.Reversible) { $tags.Children.Add((New-WinUtilGuidedBadge -Text $(if ($isSpanish) { 'No se puede deshacer' } else { 'Cannot be undone' }) -Color '#E07B24')) | Out-Null }
        [Windows.Controls.Grid]::SetColumn($tags, 2)

        $change = New-Object Windows.Controls.Button
        $change.Content = if ($isSpanish) { 'Cambiar' } else { 'Change' }
        $change.Width = [double]::NaN
        $change.Height = 30
        $change.Margin = '4,4,10,4'
        $change.Tag = [int]$item.Index
        $change.Add_Click({
            $sync.GuidedState.ReturnToSummary = $true
            Show-WinUtilGuidedQuestion -Index ([int]$this.Tag)
        })
        [Windows.Controls.Grid]::SetColumn($change, 3)

        foreach ($cell in @($category, $label, $tags, $change)) { $grid.Children.Add($cell) | Out-Null }
        $list.Children.Add($grid) | Out-Null
        $row++
    }

    $sync.WPFGuidedApply.Content = if ($isSpanish) { "Aplicar $count cambios" } else { "Apply $count changes" }
    $sync.WPFGuidedApply.IsEnabled = ($count -gt 0)
    $sync.WPFGuidedReview.Content = if ($isSpanish) { 'Revisar en modo avanzado' } else { 'Review in advanced mode' }
    $sync.WPFGuidedSummaryBack.Content = if ($isSpanish) { 'Atrás' } else { 'Back' }
    Show-WinUtilGuidedPanel -Panel 'Summary'
}

function Invoke-WinUtilGuidedReview {
    $sync.GuidedReviewPlan = $sync.GuidedPlan
    Exit-WinUtilGuided
}

function Complete-WinUtilGuidedReview {
    # Marks the plan in the main window's Tweaks tab instead of applying it.
    # Toggle switches apply on click, so they are listed rather than flipped.
    $plan = $sync.GuidedReviewPlan
    $sync.GuidedReviewPlan = $null
    if (-not $plan) { return }
    Invoke-WPFTab 'WPFTab2BT'

    $selection = @($plan.Tweaks)
    if ($plan.RestorePoint) { $selection = @('WPFTweaksRestorePoint') + $selection }
    Invoke-WPFPresets -preset $selection -imported $true -checkboxfilterpattern 'WPFTweak*'
    foreach ($change in @($plan.GroupChanges) + @($plan.TaskChanges)) {
        $checkbox = $sync[$change.Key]
        if ($checkbox -and $checkbox.IsEnabled -and $checkbox.IsChecked -ne $true) { $checkbox.IsChecked = $true }
    }

    $toggleNames = @($plan.Toggles | Where-Object {
        [bool](Get-WinUtilToggleStatus -ToggleSwitch $_.Key) -ne [bool]$_.State
    } | ForEach-Object {
        $localized = Get-WinUtilLocalizedEntry -Key $_.Key
        $name = if ($localized -and $localized.Content) { $localized.Content } else { $sync.configs.tweaks.$($_.Key).Content }
        $state = if ($_.State) { 'ON' } else { 'OFF' }
        "$name -> $state"
    })
    if ($plan.PowerPlan) {
        $toggleNames += "$(Get-WinUtilGuidedStepLabel -Key 'WPFAddUltPerf') -> $(if ((Get-WinUtilGuidedLanguage) -eq 'es') { 'botón en Planes de rendimiento' } else { 'button under Performance Plans' })"
    }
    if ($toggleNames.Count -gt 0) {
        $message = if ((Get-WinUtilGuidedLanguage) -eq 'es') {
            "Se marcaron los ajustes del modo guiado. Estos interruptores se aplican al instante, así que no se cambiaron; ajústalos tú en Personalizar preferencias:`n`n$($toggleNames -join "`n")"
        } else {
            "The guided choices are now selected. These switches apply instantly, so they were not changed; set them yourself in Customize Preferences:`n`n$($toggleNames -join "`n")"
        }
        Show-WinUtilMessage -Title 'APBOptimizer' -Message (Convert-WinUtilTextEncoding -Text $message) -Button 'OK' -Icon 'Information' | Out-Null
    }
}

function Step-WinUtilGuidedJob {
    # The main window's progress bar may be hidden, so the guided window
    # shows the same progress on its own bar.
    param([string]$Status, [int]$Percent)
    Step-WinUtilJob -Status $Status -Percent $Percent
    if (Test-WinUtilUIAlive) {
        Invoke-WPFUIThread -Async -Parameters @{ Status = $Status; Percent = $Percent } -ScriptBlock {
            param($Status, $Percent)
            if ($sync.WPFGuidedJobProgress) {
                $sync.WPFGuidedJobProgress.Value = $Percent
                $sync.WPFGuidedJobLabel.Text = $Status
            }
        }
    }
}

function Get-WinUtilGuidedStepLabel {
    param([Parameter(Mandatory)][string]$Key)
    $localized = if ($sync.configs.es) { $sync.configs.es.PSObject.Properties[$Key] } else { $null }
    $name = if ($localized -and $localized.Value.Content) { $localized.Value.Content } elseif ($sync.configs.tweaks.$Key.Content) { $sync.configs.tweaks.$Key.Content } else { $Key }
    return Convert-WinUtilTextEncoding -Text ([string]$name)
}

function Get-WinUtilGuidedErrorMark {
    if ($null -eq $sync.LoggedErrors) { return 0 }
    return $sync.LoggedErrors.Count
}

function Add-WinUtilGuidedFailures {
    # Errors logged since -Since belong to the step that just ran, so the finish
    # screen can say which change failed and why.
    param(
        [Parameter(Mandatory)][string]$Key,
        [int]$Since,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Failures
    )
    if ($null -eq $sync.LoggedErrors) { return }
    foreach ($entry in @($sync.LoggedErrors.ToArray() | Select-Object -Skip $Since)) {
        $message = ([string]$entry) -replace '^\[[^\]]*\]\s*', '' -replace '^Non-terminating error\s*:\s*', ''
        $Failures.Add([pscustomobject]@{ Step = (Get-WinUtilGuidedStepLabel -Key $Key); Message = $message })
    }
}

function Invoke-WinUtilGuidedApply {
    $plan = $sync.GuidedPlan
    if (-not $plan -or @($plan.Items).Count -eq 0) { return }
    if ($sync.ActiveJob) {
        Show-WinUtilMessage -Message "$($sync.ActiveJob) sigue en curso. Espera a que termine antes de aplicar." -Title 'APBOptimizer' -Button 'OK' -Icon 'Warning' | Out-Null
        return
    }

    $isSpanish = ((Get-WinUtilGuidedLanguage) -eq 'es')
    $sync.WPFGuidedDoneTitle.Text = if ($isSpanish) { 'Aplicando cambios...' } else { 'Applying changes...' }
    $sync.WPFGuidedDoneText.Text = if ($isSpanish) { 'Si algo falla, el resto continúa y queda registrado en el log.' } else { 'If something fails, the rest continues and it is written to the log.' }
    $sync.WPFGuidedDoneButtons.Visibility = 'Collapsed'
    $sync.WPFGuidedErrors.Visibility = 'Collapsed'
    $sync.WPFGuidedJobPanel.Visibility = 'Visible'
    $sync.WPFGuidedJobProgress.Value = 0
    $sync.WPFGuidedJobLabel.Text = ''
    Show-WinUtilGuidedPanel -Panel 'Done'
    $sync.GuidedState.Completed = $true

    Write-WinUtilLog -Component 'Guided' -Message "Guided apply requested: restore point $($plan.RestorePoint), power plan $($plan.PowerPlan), $(@($plan.Tweaks).Count) tweak(s), $(@($plan.Toggles).Count) toggle(s), $(@($plan.GroupChanges).Count) service change(s), $(@($plan.TaskChanges).Count) task change(s)."

    Start-WinUtilJob -Name 'Guided' -Description 'Applying guided mode changes' -Parameters @{
        RestorePoint = [bool]$plan.RestorePoint
        PowerPlan = [bool]$plan.PowerPlan
        Tweaks = @($plan.Tweaks)
        Toggles = @($plan.Toggles)
        GroupChanges = @($plan.GroupChanges)
        TaskChanges = @($plan.TaskChanges)
        Reboot = [bool]$plan.Reboot
    } -ScriptBlock {
        param($RestorePoint, $PowerPlan, $Tweaks, $Toggles, $GroupChanges, $TaskChanges, $Reboot)

        $totalSteps = [Math]::Max(([int]$RestorePoint + [int]$PowerPlan + @($Tweaks).Count + @($Toggles).Count + @($GroupChanges).Count + @($TaskChanges).Count), 1)
        $completedSteps = 0
        $failures = [System.Collections.Generic.List[object]]::new()

        # The restore point has to be taken before anything else changes.
        if ($RestorePoint) {
            Step-WinUtilGuidedJob -Status 'Creating restore point' -Percent 0
            $errorMark = Get-WinUtilGuidedErrorMark
            Measure-WinUtilStep -Scope 'Guided' -Name 'WPFTweaksRestorePoint' -ScriptBlock {
                Invoke-WinUtilTweaks 'WPFTweaksRestorePoint'
            }
            Add-WinUtilGuidedFailures -Key 'WPFTweaksRestorePoint' -Since $errorMark -Failures $failures
            $completedSteps++
        }
        # Before the tweaks: the USB/PCIe power tweak writes to the active plan,
        # so the new plan has to be active first.
        if ($PowerPlan) {
            Step-WinUtilGuidedJob -Status "Applying WPFAddUltPerf ($($completedSteps + 1)/$totalSteps)" -Percent ([int](($completedSteps / $totalSteps) * 100))
            $errorMark = Get-WinUtilGuidedErrorMark
            Measure-WinUtilStep -Scope 'Guided' -Name 'WPFAddUltPerf' -ScriptBlock {
                try { Invoke-WPFUltimatePerformance -Enable } catch {
                    Write-WinUtilErrorRecord -ErrorRecord $_ -Component 'Guided' -Context 'Ultimate Performance plan'
                }
            }
            Add-WinUtilGuidedFailures -Key 'WPFAddUltPerf' -Since $errorMark -Failures $failures
            $completedSteps++
        }
        foreach ($tweak in @($Tweaks)) {
            Step-WinUtilGuidedJob -Status "Applying $tweak ($($completedSteps + 1)/$totalSteps)" -Percent ([int](($completedSteps / $totalSteps) * 100))
            $errorMark = Get-WinUtilGuidedErrorMark
            Measure-WinUtilStep -Scope 'Guided' -Name $tweak -ScriptBlock {
                Invoke-WinUtilTweaks $tweak
            }
            Add-WinUtilGuidedFailures -Key $tweak -Since $errorMark -Failures $failures
            $completedSteps++
        }
        foreach ($toggle in @($Toggles)) {
            $key = [string]$toggle.Key
            $desired = [bool]$toggle.State
            Step-WinUtilGuidedJob -Status "Applying $key ($($completedSteps + 1)/$totalSteps)" -Percent ([int](($completedSteps / $totalSteps) * 100))
            $errorMark = Get-WinUtilGuidedErrorMark
            Measure-WinUtilStep -Scope 'Guided' -Name $key -ScriptBlock {
                # Only flip a switch that is not already in the chosen state.
                try {
                    if ([bool](Get-WinUtilToggleStatus -ToggleSwitch $key -BypassCache) -ne $desired) {
                        Invoke-WinUtilTweaks -CheckBox $key -undo (-not $desired)
                    }
                    if ($null -ne $sync.ToggleStatusCache) {
                        $sync.ToggleStatusCache[$key] = [bool](Get-WinUtilToggleStatus -ToggleSwitch $key -BypassCache)
                    }
                } catch {
                    Write-WinUtilErrorRecord -ErrorRecord $_ -Component 'Guided' -Context "Toggle $key"
                }
            }
            Add-WinUtilGuidedFailures -Key $key -Since $errorMark -Failures $failures
            $completedSteps++
        }
        foreach ($groupChange in @($GroupChanges)) {
            $key = [string]$groupChange.Key
            Step-WinUtilGuidedJob -Status "Applying service $key ($($completedSteps + 1)/$totalSteps)" -Percent ([int](($completedSteps / $totalSteps) * 100))
            $errorMark = Get-WinUtilGuidedErrorMark
            Measure-WinUtilStep -Scope 'Guided' -Name $key -ScriptBlock {
                Invoke-WinUtilPendingGroupChanges -Changes @($groupChange)
            }
            Add-WinUtilGuidedFailures -Key $key -Since $errorMark -Failures $failures
            $completedSteps++
        }
        if (@($TaskChanges).Count -gt 0) {
            # One scheduler read decides which tasks exist on this PC.
            $taskSnapshot = $null
            $errorMark = Get-WinUtilGuidedErrorMark
            try { $taskSnapshot = @(Get-ScheduledTask -ErrorAction Stop) } catch {
                Write-WinUtilErrorRecord -ErrorRecord $_ -Component 'Guided' -Context 'Read scheduled tasks'
            }
            Add-WinUtilGuidedFailures -Key 'WPFTaskGroupTelemetry' -Since $errorMark -Failures $failures
        }
        foreach ($taskChange in @($TaskChanges)) {
            $key = [string]$taskChange.Key
            Step-WinUtilGuidedJob -Status "Applying task $key ($($completedSteps + 1)/$totalSteps)" -Percent ([int](($completedSteps / $totalSteps) * 100))
            if ($null -ne $taskSnapshot) {
                $errorMark = Get-WinUtilGuidedErrorMark
                Measure-WinUtilStep -Scope 'Guided' -Name $key -ScriptBlock {
                    try {
                        $taskName = $sync.configs.tweaks.$key.scheduledTask.Name
                        $info = Get-WinUtilTelemetryTaskInfo -Name $taskName -TaskSnapshot $taskSnapshot
                        if ($info.Present) {
                            Invoke-WinUtilPendingTaskChanges -Changes @($taskChange)
                        } else {
                            Write-WinUtilLog -Component 'Guided' -Message "Scheduled task '$taskName' is not on this PC. Skipping."
                        }
                    } catch {
                        Write-WinUtilErrorRecord -ErrorRecord $_ -Component 'Guided' -Context "Task $key"
                    }
                }
                Add-WinUtilGuidedFailures -Key $key -Since $errorMark -Failures $failures
            }
            $completedSteps++
        }

        if (Test-WinUtilUIAlive) {
            Invoke-WPFUIThread -Parameters @{ Errors = [int]$global:WinUtilJobErrorCount; Reboot = [bool]$Reboot; Failures = @($failures) } -ScriptBlock {
                param($Errors, $Reboot, $Failures)
                Complete-WinUtilGuidedApply -Errors $Errors -Reboot $Reboot -Failures $Failures
            }
        }
    }
}

function Complete-WinUtilGuidedApply {
    param([int]$Errors, [bool]$Reboot, [object[]]$Failures = @())
    $isSpanish = ((Get-WinUtilGuidedLanguage) -eq 'es')
    $sync.WPFGuidedDoneTitle.Text = if ($Errors -gt 0) {
        if ($isSpanish) { "Terminado con $Errors error(es)" } else { "Finished with $Errors error(s)" }
    } elseif ($isSpanish) { 'Listo: cambios aplicados' } else { 'Done: changes applied' }
    $lines = @()
    if ($Errors -gt 0) {
        $lines += if (@($Failures).Count -gt 0) {
            if ($isSpanish) { 'Algunos cambios no se pudieron aplicar; el resto sí. Abajo está cada error.' } else { 'Some changes could not be applied; the rest were. Each error is listed below.' }
        } elseif ($isSpanish) { 'Algunos cambios no se pudieron aplicar; el resto sí. El log indica cuáles y por qué.' } else { 'Some changes could not be applied; the rest were. The log says which ones and why.' }
    }
    $lines += if ($Reboot) {
        if ($isSpanish) { 'Reinicia Windows para terminar de aplicar algunos cambios.' } else { 'Restart Windows to finish applying some changes.' }
    } elseif ($isSpanish) { 'Los cambios ya están activos.' } else { 'The changes are already active.' }
    $sync.WPFGuidedDoneText.Text = $lines -join ' '
    $sync.WPFGuidedErrorsList.Children.Clear()
    foreach ($failure in @($Failures)) {
        $row = New-Object Windows.Controls.TextBlock
        $row.TextWrapping = 'Wrap'
        $row.FontSize = 13
        $row.Margin = '0,0,0,8'
        $row.Background = [Windows.Media.Brushes]::Transparent
        $row.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, 'MainForegroundColor')
        $stepRun = New-Object Windows.Documents.Run -ArgumentList (Convert-WinUtilTextEncoding -Text ([string]$failure.Step))
        $stepRun.FontWeight = 'Bold'
        $row.Inlines.Add($stepRun) | Out-Null
        $row.Inlines.Add((New-Object Windows.Documents.LineBreak)) | Out-Null
        $row.Inlines.Add((New-Object Windows.Documents.Run -ArgumentList (Convert-WinUtilTextEncoding -Text ([string]$failure.Message)))) | Out-Null
        $sync.WPFGuidedErrorsList.Children.Add($row) | Out-Null
    }
    $sync.WPFGuidedErrors.Visibility = if (@($Failures).Count -gt 0) { 'Visible' } else { 'Collapsed' }
    $sync.WPFGuidedJobProgress.Value = 100
    $sync.WPFGuidedJobPanel.Visibility = 'Collapsed'
    $sync.WPFGuidedDoneAdvanced.Content = if ($isSpanish) { 'Ir al modo avanzado' } else { 'Go to advanced mode' }
    $sync.WPFGuidedDoneHome.Content = if ($isSpanish) { 'Volver al inicio' } else { 'Back to start' }
    $sync.WPFGuidedRestart.Content = if ($isSpanish) { 'Reiniciar ahora' } else { 'Restart now' }
    $sync.WPFGuidedRestart.Visibility = if ($Reboot) { 'Visible' } else { 'Collapsed' }
    $sync.WPFGuidedDoneButtons.Visibility = 'Visible'

    # Redraw the Tweaks tab from the new state; import mode keeps the redraw
    # from re-running any toggle.
    if ($sync.InitializedTabs -and $sync.InitializedTabs['Tweaks']) {
        $wasImporting = $sync.ImportInProgress
        $sync.ImportInProgress = $true
        try {
            Invoke-WPFUIElements -configVariable $sync.configs.tweaks -targetGridName 'tweakspanel' -columncount 2
            Reset-WPFCheckBoxes -doToggles $true
            Find-TweaksByNameOrDescription -SearchString $sync.SearchBar.Text
        } catch {
            Write-WinUtilErrorRecord -ErrorRecord $_ -Component 'Guided' -Context 'Refresh Tweaks tab'
        } finally { $sync.ImportInProgress = $wasImporting }
    }
}

function Restart-WinUtilComputer {
    $message = if ((Get-WinUtilGuidedLanguage) -eq 'es') {
        'Windows se reiniciará ahora. Guarda tu trabajo y cierra los programas abiertos antes de continuar. ¿Reiniciar?'
    } else { 'Windows will restart now. Save your work and close open programs before continuing. Restart?' }
    if ([string](Show-WinUtilMessage -Title 'APBOptimizer' -Message (Convert-WinUtilTextEncoding -Text $message) -Button 'YesNo' -Icon 'Warning') -ne 'Yes') { return }
    Write-WinUtilLog -Component 'Guided' -Message 'Restart requested from guided mode.'
    Restart-Computer -Force
}

function Invoke-WinUtilScript {
    <#

    .SYNOPSIS
        Invokes the provided scriptblock. Intended for things that can't be handled with the other functions.

    .PARAMETER Name
        The name of the scriptblock being invoked

    .PARAMETER scriptblock
        The scriptblock to be invoked

    .EXAMPLE
        $Scriptblock = [scriptblock]::Create({"Write-output 'Hello World'"})
        Invoke-WinUtilScript -ScriptBlock $scriptblock -Name "Hello World"

    #>
    param (
        $Name,
        [scriptblock]$scriptblock
    )

    try {
        Write-Host "Running Script for $Name"
        Write-WinUtilLog -Component "Script" -Message "Running script for $Name"
        Invoke-Command $scriptblock -ErrorAction Stop
        Write-WinUtilLog -Component "Script" -Message "Completed script for $Name"
    } catch [System.Management.Automation.CommandNotFoundException] {
        Write-Warning "The specified command was not found."
        Write-Warning $PSItem.Exception.message
        Write-WinUtilLog -Level "ERROR" -Component "Script" -Message "Command not found while running script for $Name`: $($PSItem.Exception.Message)"
    } catch [System.Management.Automation.RuntimeException] {
        Write-Warning "A runtime exception occurred."
        Write-Warning $PSItem.Exception.message
        Write-WinUtilLog -Level "ERROR" -Component "Script" -Message "Runtime exception while running script for $Name`: $($PSItem.Exception.Message)"
    } catch [System.Security.SecurityException] {
        Write-Warning "A security exception occurred."
        Write-Warning $PSItem.Exception.message
        Write-WinUtilLog -Level "ERROR" -Component "Script" -Message "Security exception while running script for $Name`: $($PSItem.Exception.Message)"
    } catch [System.UnauthorizedAccessException] {
        Write-Warning "Access denied. You do not have permission to perform this operation."
        Write-Warning $PSItem.Exception.message
        Write-WinUtilLog -Level "ERROR" -Component "Script" -Message "Access denied while running script for $Name`: $($PSItem.Exception.Message)"
    } catch {
        # Generic catch block to handle any other type of exception
        Write-Warning "Unable to run script for $Name due to unhandled exception."
        Write-Warning $psitem.Exception.StackTrace
        Write-WinUtilLog -Level "ERROR" -Component "Script" -Message "Unhandled exception while running script for $Name`: $($psitem.Exception.Message)"
    }

}

function Invoke-WinutilThemeChange {
    <#
    .SYNOPSIS
        Toggles between light and dark themes for a Windows utility application.

    .DESCRIPTION
        This function toggles the theme of the user interface between 'Light' and 'Dark' modes,
        modifying various UI elements such as colors, margins, corner radii, font families, etc.
        If the '-init' switch is used, it initializes the theme based on the system's current dark mode setting.

    .EXAMPLE
        Invoke-WinutilThemeChange
        # Toggles the theme between 'Light' and 'Dark'.


    #>
    param (
        [string]$theme = "Auto"
    )

    function Set-WinutilTheme {
        <#
        .SYNOPSIS
            Applies the specified theme to the application's user interface.

        .DESCRIPTION
            This internal function applies the given theme by setting the relevant properties
            like colors, font families, corner radii, etc., in the UI. It uses the
            'Set-ThemeResourceProperty' helper function to modify the application's resources.

        .PARAMETER currentTheme
            The name of the theme to be applied. Common values are "Light", "Dark", or "shared".
        #>
        param (
            [string]$currentTheme
        )

        function Set-ThemeResourceProperty {
            <#
            .SYNOPSIS
                Sets a specific UI property in the application's resources.

            .DESCRIPTION
                This helper function sets a property (e.g., color, margin, corner radius) in the
                application's resources, based on the provided type and value. It includes
                error handling to manage potential issues while setting a property.

            .PARAMETER Name
                The name of the resource property to modify (e.g., "MainBackgroundColor", "ButtonBackgroundMouseoverColor").

            .PARAMETER Value
                The value to assign to the resource property (e.g., "#FFFFFF" for a color).

            .PARAMETER Type
                The type of the resource, such as "ColorBrush", "CornerRadius", "GridLength", or "FontFamily".
            #>
            param($Name, $Value, $Type)
            try {
                # Set the resource property based on its type
                $sync.Form.Resources[$Name] = switch ($Type) {
                    "ColorBrush" { [Windows.Media.SolidColorBrush]::new($Value) }
                    "Color" {
                        # Convert hex string to RGB values
                        $hexColor = $Value.TrimStart("#")
                        $r = [Convert]::ToInt32($hexColor.Substring(0,2), 16)
                        $g = [Convert]::ToInt32($hexColor.Substring(2,2), 16)
                        $b = [Convert]::ToInt32($hexColor.Substring(4,2), 16)
                        [Windows.Media.Color]::FromRgb($r, $g, $b)
                    }
                    "CornerRadius" { [System.Windows.CornerRadius]::new($Value) }
                    "GridLength" { [System.Windows.GridLength]::new($Value) }
                    "Thickness" {
                        # Parse the Thickness value (supports 1, 2, or 4 inputs)
                        $values = $Value -split ","
                        switch ($values.Count) {
                            1 { [System.Windows.Thickness]::new([double]$values[0]) }
                            2 { [System.Windows.Thickness]::new([double]$values[0], [double]$values[1]) }
                            4 { [System.Windows.Thickness]::new([double]$values[0], [double]$values[1], [double]$values[2], [double]$values[3]) }
                        }
                    }
                    "FontFamily" { [Windows.Media.FontFamily]::new($Value) }
                    "Double" { [double]$Value }
                    default { $Value }
                }
            }
            catch {
                # Log a warning if there's an issue setting the property
                Write-Warning "Failed to set property $($Name): $_"
            }
        }

        # Retrieve all theme properties from the theme configuration
        $themeProperties = $sync.configs.themes.$currentTheme.PSObject.Properties
        foreach ($themeProperty in $themeProperties) {
            # Apply properties that deal with colors
            if ($themeProperty.Name -like "*color*") {
                Set-ThemeResourceProperty -Name $themeProperty.Name -Value $themeProperty.Value -Type "ColorBrush"
                # For certain color properties, also set complementary values (e.g., BorderColor -> CBorderColor) This is required because e.g DropShadowEffect requires a <Color> and not a <SolidColorBrush> object
                if ($themeProperty.Name -in @("BorderColor", "ButtonBackgroundMouseoverColor")) {
                    Set-ThemeResourceProperty -Name "C$($themeProperty.Name)" -Value $themeProperty.Value -Type "Color"
                }
            }
            # Apply corner radius properties
            elseif ($themeProperty.Name -like "*Radius*") {
                Set-ThemeResourceProperty -Name $themeProperty.Name -Value $themeProperty.Value -Type "CornerRadius"
            }
            # Apply row height properties
            elseif ($themeProperty.Name -like "*RowHeight*") {
                Set-ThemeResourceProperty -Name $themeProperty.Name -Value $themeProperty.Value -Type "GridLength"
            }
            # Apply thickness or margin properties
            elseif (($themeProperty.Name -like "*Thickness*") -or ($themeProperty.Name -like "*margin")) {
                Set-ThemeResourceProperty -Name $themeProperty.Name -Value $themeProperty.Value -Type "Thickness"
            }
            # Apply font family properties
            elseif ($themeProperty.Name -like "*FontFamily*") {
                Set-ThemeResourceProperty -Name $themeProperty.Name -Value $themeProperty.Value -Type "FontFamily"
            }
            # Apply any other properties as doubles (numerical values)
            else {
                Set-ThemeResourceProperty -Name $themeProperty.Name -Value $themeProperty.Value -Type "Double"
            }
        }
    }

    $sync.preferences.theme = $theme
    Set-WinutilTheme -currentTheme "shared"

    switch ($sync.preferences.theme) {
        "Auto" {
            $systemUsesDarkMode = Get-WinUtilToggleStatus WPFToggleDarkMode
            if ($systemUsesDarkMode) {
                $theme = "Dark"
            }
            else{
                $theme = "Light"
            }

            Set-WinutilTheme -currentTheme $theme
            $themeButtonIcon = [char]0xF08C
        }
        "Dark" {
            Set-WinutilTheme -currentTheme $sync.preferences.theme
            $themeButtonIcon = [char]0xE708
           }
        "Light" {
            Set-WinutilTheme -currentTheme $sync.preferences.theme
            $themeButtonIcon = [char]0xE706
        }
    }

    # Reapply font scaling if it was previously set (theme change resets shared resources)
    if ($sync.ContainsKey("FontScaleFactor") -and $sync.FontScaleFactor -ne 1.0) {
        Invoke-WinUtilFontScaling -ScaleFactor $sync.FontScaleFactor
    }

    # Update the theme selector button with the appropriate icon
    $ThemeButton = $sync.Form.FindName("ThemeButton")
    $ThemeButton.Content = [string]$themeButtonIcon
}

function Invoke-WinUtilTweaks {
    <#

    .SYNOPSIS
        Invokes the function associated with each provided checkbox

    .PARAMETER CheckBox
        The checkbox to invoke

    .PARAMETER undo
        Indicates whether to undo the operation contained in the checkbox

    .PARAMETER KeepServiceStartup
        Indicates whether to override the startup of a service with the one given from WinUtil,
        or to keep the startup of said service, if it was changed by the user, or another program, from its default value.
    #>

    param(
        $CheckBox,
        $undo = $false,
        $KeepServiceStartup = $true
    )

    $action = if ($undo) { "Undo" } else { "Apply" }
    Write-WinUtilLog -Component "Tweaks" -Message "$action tweak: $CheckBox"
    # The counter lives in this runspace, so an error a concurrent job logs from its own
    # runspace cannot be charged to a toggle flipped on the UI thread
    $errorsBefore = [int]$global:WinUtilJobErrorCount

    if ($undo) {
        $Values = @{
            Registry = "OriginalValue"
            Service = "OriginalType"
            ScriptType = "UndoScript"
        }

    } else {
        $Values = @{
            Registry = "Value"
            Service = "StartupType"
            OriginalService = "OriginalType"
            ScriptType = "InvokeScript"
        }
    }
    if ($sync.configs.tweaks.$CheckBox.service) {
        $sync.configs.tweaks.$CheckBox.service | ForEach-Object {
            $changeservice = $true

        # The check for !($undo) is required, without it the script will throw an error for accessing unavailable member, which's the 'OriginalService' Property
            # Dedicated, user-selected service tweaks may explicitly opt out of the
            # default protection for a preexisting custom startup type.
            if ($KeepServiceStartup -AND !($undo) -AND $psitem.ForceStartup -ne $true) {
                $serviceName = $psitem.Name
                try {
                    # Check if the service exists
                    $service = Get-Service -Name $serviceName -ErrorAction Stop
                    if(!($service.StartType.ToString() -eq $psitem.$($values.OriginalService))) {
                        $changeservice = $false
                    }
                } catch {
                    if ($_.FullyQualifiedErrorId -like "NoServiceFoundForGivenName,*") {
                        $changeservice = $false
                        Write-Warning "Service $serviceName was not found."
                        Write-WinUtilLog -Level "WARN" -Component "Service" -Message "Service $serviceName was not found."
                    } else {
                        throw
                    }
                }
            }

            if ($changeservice) {
                Set-WinUtilService -Name $psitem.Name -StartupType $psitem.$($values.Service)
            }
        }
    }
    if ($sync.configs.tweaks.$CheckBox.registry) {
        $sync.configs.tweaks.$CheckBox.registry | Where-Object { -not $psitem.Values } | ForEach-Object {
            Set-WinUtilRegistry -Name $psitem.Name -Path $psitem.Path -Type $psitem.Type -Value $psitem.$($values.registry)
        }
    }
    if ($sync.configs.tweaks.$CheckBox.$($values.ScriptType)) {
        $sync.configs.tweaks.$CheckBox.$($values.ScriptType) | ForEach-Object {
            $Scriptblock = [scriptblock]::Create($psitem)
            Invoke-WinUtilScript -ScriptBlock $scriptblock -Name $CheckBox
        }
    }

    if (!$undo) {
        if($sync.configs.tweaks.$CheckBox.appx) {
            $sync.configs.tweaks.$CheckBox.appx | ForEach-Object {
                Remove-WinUtilAPPX -Name $psitem
            }
            Remove-WinUtilProvisionedAPPX -PackageList $sync.configs.tweaks.$CheckBox.appx
        }
    }
    $errorCount = [int]$global:WinUtilJobErrorCount - $errorsBefore
    if ($errorCount -gt 0) {
        Write-WinUtilLog -Level "WARN" -Component "Tweaks" -Message "$action tweak finished with $errorCount error(s): $CheckBox"
    } else {
        Write-WinUtilLog -Component "Tweaks" -Message "$action tweak completed: $CheckBox"
    }
}

function Measure-WinUtilStep {
    <#
        .SYNOPSIS
            Times one step of a pipeline and records it for the timing summary

        .DESCRIPTION
            Output passes through untouched, so this can wrap an existing expression without
            changing what the caller receives. Each step is logged as a "timing:" line and kept
            in $sync.StepTimings for the summary to rank.

        .PARAMETER Name
            What the step is, as it should read in the log.

        .PARAMETER ScriptBlock
            The work to time.

        .PARAMETER Scope
            Groups steps that belong to the same run, normally a job name or "UI".
    #>
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Name,

        [Parameter(Mandatory, Position = 1)]
        [scriptblock]$ScriptBlock,

        [string]$Scope = "WinUtil"
    )

    $isUIDiagnostic = $Scope -in @("UI", "Tab")
    $captureTiming = -not $isUIDiagnostic -or $sync.IsLocalCompile
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        & $ScriptBlock
    } finally {
        $stopwatch.Stop()

        if ($captureTiming -and $null -ne $sync.StepTimings) {
            $null = $sync.StepTimings.Add([pscustomobject]@{
                Scope = $Scope
                Step = $Name
                Milliseconds = $stopwatch.ElapsedMilliseconds
            })
        }

        if ($captureTiming) {
            $level = if ($isUIDiagnostic) { "DEBUG" } else { "INFO" }
            Write-WinUtilLog -Level $level -Component $Scope -Message "timing: $Name took $($stopwatch.ElapsedMilliseconds) ms"
        }
    }
}

function Write-WinUtilTimingSummary {
    <#
        .SYNOPSIS
            Logs the slowest steps of a scope, so the log answers "what took so long"

        .PARAMETER Scope
            Which group of steps to report on.

        .PARAMETER Top
            How many of the slowest steps to list.

        .PARAMETER TotalMilliseconds
            Wall clock total. Without it the summary sums the steps, missing whatever happened
            between them.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Scope,

        [int]$Top = 5,

        [long]$TotalMilliseconds = -1,

        [int]$StartIndex = 0
    )

    $isUIDiagnostic = $Scope -in @("UI", "Tab")
    if (($isUIDiagnostic -and -not $sync.IsLocalCompile) -or $null -eq $sync.StepTimings) {
        return
    }

    [System.Threading.Monitor]::Enter($sync.StepTimings.SyncRoot)
    try {
        $timingSnapshot = @($sync.StepTimings.ToArray())
    } finally {
        [System.Threading.Monitor]::Exit($sync.StepTimings.SyncRoot)
    }

    $steps = @($timingSnapshot | Select-Object -Skip $StartIndex | Where-Object { $_.Scope -eq $Scope })
    if ($steps.Count -eq 0) {
        return
    }

    $measured = ($steps | Measure-Object -Property Milliseconds -Sum).Sum
    $total = if ($TotalMilliseconds -ge 0) { $TotalMilliseconds } else { $measured }

    $level = if ($isUIDiagnostic) { "DEBUG" } else { "INFO" }
    Write-WinUtilLog -Level $level -Component $Scope -Message "timing summary: $($steps.Count) step(s), $measured ms measured of $total ms total"
    foreach ($step in ($steps | Sort-Object Milliseconds -Descending | Select-Object -First $Top)) {
        $share = if ($total -gt 0) { [int](($step.Milliseconds / $total) * 100) } else { 0 }
        Write-WinUtilLog -Level $level -Component $Scope -Message "timing summary:   $($step.Milliseconds) ms ($share%)  $($step.Step)"
    }
}

function New-WinUtilFossBadge {
    <#
        .SYNOPSIS
            Creates the FOSS marker: the open source keyhole on a green backdrop
        .DESCRIPTION
            Returns a fresh element on every call, because a WPF element can only have one parent.
            The artwork is authored in a 22x22 box and scaled by the Viewbox, so callers only pick a size.
        .PARAMETER Size
            Edge length of the badge in pixels
        .PARAMETER Round
            Use a full circle instead of the corner triangle, for the legend rather than an app entry
    #>
    param(
        [double]$Size = 24,
        [switch]$Round
    )

    $artwork = New-Object Windows.Controls.Grid
    $artwork.Width = 22
    $artwork.Height = 22

    $backdrop = New-Object Windows.Shapes.Path
    $backdrop.Fill = [Windows.Media.SolidColorBrush]::new([Windows.Media.Color]::FromRgb(19, 143, 83))
    $keyhole = New-Object Windows.Shapes.Path
    $keyhole.Stroke = [Windows.Media.SolidColorBrush]::new([Windows.Media.Color]::FromRgb(247, 247, 247))

    if ($Round) {
        $backdrop.Data = [Windows.Media.EllipseGeometry]::new([Windows.Point]::new(11, 11), 11, 11)
        # Keyhole centred in the circle, which has room for a larger ring than the triangle does
        $keyhole.Data = [Windows.Media.Geometry]::Parse("M 7.673,15.751 A 5.8,5.8 0 1 1 14.327,15.751")
        $keyhole.StrokeThickness = 3.4
    } else {
        # Triangle filling the top right corner, its outer corner rounded to match AppEntryBorderStyle
        $backdrop.Data = [Windows.Media.Geometry]::Parse("M 0,0 L 17,0 A 5,5 0 0 1 22,5 L 22,22 Z")
        # Keyhole centred on the triangle's incentre (15.56, 6.44) so it keeps the same
        # 1.8 clearance from all three edges
        $keyhole.Data = [Windows.Media.Geometry]::Parse("M 13.61,9.225 A 3.4,3.4 0 1 1 17.51,9.225")
        $keyhole.StrokeThickness = 2.4
    }

    $keyhole.StrokeStartLineCap = [Windows.Media.PenLineCap]::Round
    $keyhole.StrokeEndLineCap = [Windows.Media.PenLineCap]::Round
    [void]$artwork.Children.Add($backdrop)
    [void]$artwork.Children.Add($keyhole)

    $badge = New-Object Windows.Controls.Viewbox
    $badge.Width = $Size
    $badge.Height = $Size
    $badge.Child = $artwork
    $badge.ToolTip = "Free and Open Source Software"

    return $badge
}

function New-WinUtilSessionState {
    <#
        .SYNOPSIS
            Builds the InitialSessionState every WinUtil runspace is created from

        .DESCRIPTION
            The interface runspace and the worker pool start from the same state: the shared
            $sync hashtable, the compiled script's globals, and every WinUtil function. That is
            what lets the interface build a tab and a job body call any helper without injecting
            definitions by hand. PowerShell's own functions are skipped, the default session
            state already carries them.

            Cached: an InitialSessionState is a template any number of runspaces are created
            from, and building it is not free.
    #>

    if ($sync.SessionState) {
        return $sync.SessionState
    }

    $initialSessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()

    $variables = @(
        @{ Name = "sync"; Value = $sync },
        @{ Name = "PARAM_OFFLINE"; Value = $PARAM_OFFLINE },
        @{ Name = "inputXML"; Value = $inputXML },
        @{ Name = "guidedXML"; Value = $guidedXML }
    )

    foreach ($variable in $variables) {
        $initialSessionState.Variables.Add(
            (New-Object System.Management.Automation.Runspaces.SessionStateVariableEntry -ArgumentList $variable.Name, $variable.Value, $null)
        )
    }

    $builtInFunctions = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]@($initialSessionState.Commands |
            Where-Object { $_ -is [System.Management.Automation.Runspaces.SessionStateFunctionEntry] } |
            ForEach-Object { $_.Name }),
        [StringComparer]::OrdinalIgnoreCase
    )

    foreach ($function in (Get-ChildItem function:\)) {
        if ($builtInFunctions.Contains($function.Name)) {
            continue
        }

        $initialSessionState.Commands.Add(
            (New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry -ArgumentList $function.Name, $function.Definition)
        )
    }

    $sync.SessionState = $initialSessionState
    return $initialSessionState
}

function Register-WinUtilRunspaceCleanup {
    <#
        .SYNOPSIS
            Disposes a PowerShell instance and any owned runspace once its work has finished

        .DESCRIPTION
            Ends the invocation and disposes the instance from a thread pool callback, so
            nothing has to wait for a fire-and-forget runspace to complete just to clean it up.

        .PARAMETER PowerShell
            The instance to dispose.

        .PARAMETER Handle
            The handle returned by its BeginInvoke.

        .PARAMETER Runspace
            A dedicated runspace owned by the invocation. Shared pool invocations omit it.
    #>
    param(
        [Parameter(Mandatory)]
        $PowerShell,

        [Parameter(Mandatory)]
        $Handle,

        $Runspace
    )

    # Version the CLR helper because Add-Type definitions survive repeated in-memory WinUtil runs.
    # Older sessions can already contain the V1 type, whose state object has no Runspace property.
    if (-not ("WinUtilRunspaceCleanupV3" -as [type])) {
        Add-Type @"
using System;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Threading;

public sealed class WinUtilRunspaceCleanupStateV3
{
    public PowerShell PowerShell { get; set; }
    public IAsyncResult Handle { get; set; }
    public Runspace Runspace { get; set; }
}

public static class WinUtilRunspaceCleanupV3
{
    public static readonly System.Threading.WaitOrTimerCallback Callback = Cleanup;

    public static bool Register(WinUtilRunspaceCleanupStateV3 state)
    {
        try
        {
            ThreadPool.RegisterWaitForSingleObject(state.Handle.AsyncWaitHandle, Callback, state, -1, true);
            return true;
        }
        catch
        {
            // Registration is normally infallible, but work has already started. A background
            // waiter preserves asynchronous cleanup without blocking the WPF dispatcher.
            try
            {
                var thread = new Thread(() =>
                {
                    try
                    {
                        state.Handle.AsyncWaitHandle.WaitOne();
                    }
                    catch
                    {
                    }
                    Cleanup(state, false);
                });
                thread.IsBackground = true;
                thread.Name = "WinUtil runspace cleanup fallback";
                thread.Start();
                return true;
            }
            catch
            {
                return false;
            }
        }
    }

    public static void Cleanup(object state, bool timedOut)
    {
        var cleanupState = state as WinUtilRunspaceCleanupStateV3;
        if (cleanupState == null || cleanupState.PowerShell == null || cleanupState.Handle == null)
        {
            return;
        }

        try
        {
            cleanupState.PowerShell.EndInvoke(cleanupState.Handle);
        }
        catch
        {
        }
        finally
        {
            cleanupState.PowerShell.Dispose();
            if (cleanupState.Runspace != null)
            {
                try
                {
                    cleanupState.Runspace.Close();
                }
                catch
                {
                }
                finally
                {
                    cleanupState.Runspace.Dispose();
                }
            }
        }
    }
}
"@
    }

    $cleanupState = [WinUtilRunspaceCleanupStateV3]::new()
    $cleanupState.PowerShell = $PowerShell
    $cleanupState.Handle = $Handle
    $cleanupState.Runspace = $Runspace
    $registered = [WinUtilRunspaceCleanupV3]::Register($cleanupState)
    if (-not $registered) {
        Write-WinUtilLog -Level "WARN" -Component "UI" -Message "Could not register asynchronous cleanup for background work; it will be reclaimed when later work or shutdown inspects it."
    }
}

function Remove-WinUtilAPPX {
    <#

    .SYNOPSIS
        Removes all APPX packages that match the given name

    .PARAMETER Name
        The name of the APPX package to remove

    .EXAMPLE
        Remove-WinUtilAPPX -Name "Microsoft.Microsoft3DViewer"

    #>
    param (
        $Name
    )

    Write-Host "Removing $Name"
    Write-WinUtilLog -Component "AppX" -Message "Removing AppX package pattern: $Name"

    # We explicitly loop through packages instead of using the pipeline because PowerShell 7 pipeline binding
    # for Remove-AppxPackage fails silently, and Get-AppxPackage -AllUsers returns duplicate objects for each user profile.
    $pkgs = Get-AppxPackage "*$Name*" -AllUsers | Sort-Object -Property PackageFullName -Unique
    if ($null -ne $pkgs) {
        foreach ($pkg in $pkgs) {
            try {
                Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop
            }
            catch {
                Write-WinUtilLog -Level "ERROR" -Component "AppX" -Message "Failed to remove AppX package $($pkg.PackageFullName): $($_.Exception.Message)"
            }
        }
    }

    Write-WinUtilLog -Component "AppX" -Message "AppX removal completed for package pattern: $Name"
}

function Remove-WinUtilProvisionedAPPX {
    <#

    .SYNOPSIS
        Removes all AppX provisioned packages that match the given names

    .PARAMETER PackageList
        An array of names of the APPX packages to remove

    .EXAMPLE
        Remove-WinUtilProvisionedAPPX -PackageList @("Microsoft.Microsoft3DViewer", "Microsoft.WindowsCalculator")

    #>
    param (
        [string[]]$PackageList
    )

    if ($null -eq $PackageList -or $PackageList.Count -eq 0) {
        return
    }

    Write-Host "`nRemoving provisioned packages..."
    Write-WinUtilLog -Component "AppX" -Message "Removing AppX provisioned packages: $($PackageList -join ', ')"

    # DISM cmdlets like Get-AppxProvisionedPackage often fail with "Class not registered" or hang in PowerShell 7.
    # We shell out to Windows PowerShell 5.1 (powershell.exe) to reliably remove the provisioned packages.
    $ps5Command = {
        $pkgs = $args
        $provisionedPackages = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue
        $failures = [System.Collections.Generic.List[string]]::new()

        foreach ($Package in $pkgs) {
            $provs = $provisionedPackages |
                Where-Object DisplayName -Like "*$Package*"

            if ($null -ne $provs) {
                foreach ($prov in $provs) {
                    try {
                        Remove-AppxProvisionedPackage -Online -PackageName $prov.PackageName -ErrorAction Stop | Out-Null
                    }
                    catch {
                        $failures.Add("Failed to remove provisioned AppX package $($prov.PackageName): $($_.Exception.Message)")
                    }
                }
            }
        }

        if ($failures.Count -gt 0) {
            throw ($failures -join [Environment]::NewLine)
        }
    }

    $removalOutput = powershell.exe -NoProfile -NonInteractive -Command $ps5Command -args $PackageList 2>&1
    if ($LASTEXITCODE -ne 0 -or $null -ne $removalOutput) {
        $failureDetails = ($removalOutput | Out-String).Trim()
        $errorMessage = "AppX provisioned package removal failed: $failureDetails"
        Write-WinUtilLog -Level "ERROR" -Component "AppX" -Message $errorMessage
        $exception = [System.InvalidOperationException]::new($errorMessage)
        $exception.Data["WinUtilErrorReported"] = $true
        throw $exception
    }

    Write-WinUtilLog -Component "AppX" -Message "AppX provisioned package removal completed."
}

function Reset-WPFCheckBoxes {
    <#

    .SYNOPSIS
        Set WinUtil checkboxes to match $sync.selected values.
        Should only need to be run if $sync.selected updated outside of UI (i.e. presets or import)

    .PARAMETER doToggles
        Whether or not to set UI toggles. WARNING: they will trigger if altered

    .PARAMETER checkboxfilterpattern
        The Pattern to use when filtering through CheckBoxes, defaults to "**"
        Used to make reset blazingly fast.
    #>

    param (
        [Parameter(position=0)]
        [bool]$doToggles = $false,

        [Parameter(position=1)]
        [string]$checkboxfilterpattern = "**"
    )
    $selectedSet = [System.Collections.Generic.HashSet[string]]::new([string[]]@($sync.selectedTweaks), [StringComparer]::OrdinalIgnoreCase)

    # A synchronized Hashtable protects individual operations, not enumeration. Materialize the
    # snapshot under its lock, then release it before handlers run and mutate $sync.
    [System.Threading.Monitor]::Enter($sync.SyncRoot)
    try {
        $syncEntries = @($sync.GetEnumerator())
    } finally {
        [System.Threading.Monitor]::Exit($sync.SyncRoot)
    }
    foreach ($syncEntry in $syncEntries) {
        if ($syncEntry.Value -is [System.Windows.Controls.CheckBox] -and $syncEntry.Name -notlike "WPFToggle*" -and $syncEntry.Name -notlike "WPFServiceGroup*" -and $syncEntry.Name -notlike "WPFDriverGroup*" -and $syncEntry.Name -notlike "WPFTaskGroup*" -and $syncEntry.Name -like $checkboxfilterpattern) {
            $checkboxName = $syncEntry.Key
            $sync.$checkboxName.IsChecked = $selectedSet.Contains($checkboxName)
        }
    }

    if($doToggles) {
        # Restore toggle switch states from imported config.
        # Only act on toggles that are explicitly listed in the import - toggles absent
        # from the export file were not part of the saved config and should keep whatever
        # state the live system already has (set during UI initialisation via Get-WinUtilToggleStatus).
        $importedToggles = [System.Collections.Generic.HashSet[string]]::new([string[]]@($sync.selectedToggles), [StringComparer]::OrdinalIgnoreCase)
        [System.Threading.Monitor]::Enter($sync.SyncRoot)
        try {
            $toggleEntries = @($sync.GetEnumerator())
        } finally {
            [System.Threading.Monitor]::Exit($sync.SyncRoot)
        }
        foreach ($toggle in $toggleEntries) {
            if ($toggle.Key -like "WPFToggle*" -and $toggle.Value -is [System.Windows.Controls.CheckBox] -and $importedToggles.Contains($toggle.Key)) {
                $sync[$toggle.Key].IsChecked = $true
                $parentGroup = [string]$sync.configs.tweaks.$($toggle.Key).ParentGroup
                if ($parentGroup -in @('WPFTaskGroupTelemetry', 'WPFServiceGroupDiagnostics', 'WPFServiceGroupUseless', 'WPFDriverGroupOptional') -and $sync.Form -and
                    $sync[$toggle.Key].IsEnabled -and $sync[$toggle.Key].Visibility -eq [System.Windows.Visibility]::Visible) {
                    $pendingName = if ($parentGroup -eq 'WPFTaskGroupTelemetry') {
                        'PendingTaskSelections'
                    } else {
                        'PendingGroupSelections'
                    }
                    if ($null -eq $sync[$pendingName]) {
                        $sync[$pendingName] = [hashtable]::Synchronized(@{})
                    }
                    # Import stages Apply; language redraws preserve explicit
                    # pending restores and must not create phantom operations.
                    if (-not $sync[$pendingName].ContainsKey($toggle.Key)) {
                        $actual = Get-WinUtilToggleStatus -ToggleSwitch $toggle.Key
                        if (-not $actual) { $sync[$pendingName][$toggle.Key] = $true }
                    }
                }
            }
            # Toggles not present in the import are intentionally left untouched;
            # their current UI state already reflects the real system state.
        }
    }
}

function Save-WinUtilFile {
    <#
    .SYNOPSIS
        Downloads a file and reports transfer progress.
    #>
    param(
        [Parameter(Mandatory)]
        [uri]$Uri,

        [Parameter(Mandatory)]
        [string]$DestinationPath,

        [Parameter(Mandatory)]
        [scriptblock]$ProgressCallback
    )

    $response = $null
    $responseStream = $null
    $outputStream = $null

    try {
        $request = [System.Net.WebRequest]::Create($Uri)
        $response = $request.GetResponse()
        $totalBytes = $response.ContentLength
        $responseStream = $response.GetResponseStream()
        $outputStream = [System.IO.File]::Create($DestinationPath)
        $buffer = New-Object byte[] 81920
        $downloadedBytes = 0L
        $lastPercent = -1

        while (($bytesRead = $responseStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $outputStream.Write($buffer, 0, $bytesRead)
            $downloadedBytes += $bytesRead

            if ($totalBytes -gt 0) {
                $percent = [Math]::Min(100, [int](($downloadedBytes / $totalBytes) * 100))
                if ($percent -ne $lastPercent) {
                    & $ProgressCallback $percent
                    $lastPercent = $percent
                }
            }
        }

        if ($lastPercent -ne 100) {
            & $ProgressCallback 100
        }
    }
    finally {
        if ($null -ne $outputStream) {
            $outputStream.Dispose()
        }
        if ($null -ne $responseStream) {
            $responseStream.Dispose()
        }
        if ($null -ne $response) {
            $response.Dispose()
        }
    }
}

function Get-WinUtilCPUMitigationsRegistryValue {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name)

    $result = [pscustomobject]@{ Present = $false; Kind = ''; Value = $null }
    try {
        $key = Get-Item -LiteralPath $Path -ErrorAction Stop
    } catch {
        if ($_.Exception -is [System.Management.Automation.ItemNotFoundException] -or
            $_.FullyQualifiedErrorId -like 'PathNotFound,*' -or
            $_.FullyQualifiedErrorId -like 'ItemNotFound,*') {
            return $result
        }
        throw
    }
    if ($null -eq $key -or $Name -notin @($key.GetValueNames())) { return $result }
    $result.Present = $true
    $result.Kind = [string]$key.GetValueKind($Name)
    $result.Value = $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    return $result
}

function Get-WinUtilCPUMitigationsBackup {
    $backupPath = 'HKLM:\SOFTWARE\OptiUtil\CPUMitigationsBackup'
    $saved = Get-WinUtilCPUMitigationsRegistryValue -Path $backupPath -Name Snapshot
    if (-not $saved.Present) { return $null }
    if ($saved.Kind -ne 'String' -or [string]::IsNullOrWhiteSpace([string]$saved.Value)) {
        throw 'CPU mitigations backup is unreadable. No changes made.'
    }
    try {
        $backup = ConvertFrom-Json -InputObject ([string]$saved.Value) -ErrorAction Stop
        if ($backup.Version -ne 1 -or $null -eq $backup.Values -or
            @($backup.Values.PSObject.Properties).Count -ne 2) {
            throw 'Unexpected backup schema.'
        }
        foreach ($name in @('FeatureSettingsOverride', 'FeatureSettingsOverrideMask')) {
            $entry = $backup.Values.PSObject.Properties[$name]
            if ($null -eq $entry -or $entry.Value.Present -isnot [bool]) {
                throw "Missing saved state for $name."
            }
            if ($entry.Value.Present -and ($entry.Value.Kind -ne 'DWord' -or
                $null -eq $entry.Value.Value -or [string]$entry.Value.Value -notmatch '^-?\d+$' -or
                [long]$entry.Value.Value -gt [int]::MaxValue -or
                [long]$entry.Value.Value -lt [int]::MinValue)) {
                throw "Invalid saved DWORD for $name."
            }
        }
        return $backup
    } catch {
        throw "Invalid CPU mitigations backup; original values cannot be safely restored: $($_.Exception.Message)"
    }
}

function Set-WinUtilCPUMitigations {
    param([Parameter(Mandatory)][ValidateSet('Disable', 'Restore')][string]$Mode)

    if ([Environment]::OSVersion.Version.Major -lt 10) {
        throw 'This CPU mitigation setting requires Windows 10 or Windows 11.'
    }
    if (-not (Test-WinUtilWindowsUpdateAdmin)) {
        throw 'Administrator privileges are required to configure CPU mitigations.'
    }
    $path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'
    $backupPath = 'HKLM:\SOFTWARE\OptiUtil\CPUMitigationsBackup'
    $names = @('FeatureSettingsOverride', 'FeatureSettingsOverrideMask')
    $backup = Get-WinUtilCPUMitigationsBackup

    if ($Mode -eq 'Disable') {
        $values = [ordered]@{}
        foreach ($name in $names) {
            $previous = Get-WinUtilCPUMitigationsRegistryValue -Path $path -Name $name
            if ($previous.Present -and $previous.Kind -ne 'DWord') {
                throw "Unexpected registry type for $name; refusing to overwrite it."
            }
            $values[$name] = @{
                Present = [bool]$previous.Present
                Kind = if ($previous.Present) { 'DWord' } else { '' }
                Value = if ($previous.Present) { [int]$previous.Value } else { $null }
            }
        }
        if (-not $backup) {
            $backup = @{ Version = 1; Values = $values }
            # Persist both original DWORDs (including absence) before writing either value.
            $null = New-Item -Path $backupPath -Force -ErrorAction Stop
            $null = New-ItemProperty -LiteralPath $backupPath -Name Snapshot -PropertyType String -Value ($backup | ConvertTo-Json -Depth 5 -Compress) -Force -ErrorAction Stop
        }
        $null = New-Item -Path $path -Force -ErrorAction Stop
        foreach ($name in $names) {
            $null = New-ItemProperty -LiteralPath $path -Name $name -PropertyType DWord -Value 3 -Force -ErrorAction Stop
        }
        foreach ($name in $names) {
            $actual = Get-WinUtilCPUMitigationsRegistryValue -Path $path -Name $name
            if (-not $actual.Present -or $actual.Kind -ne 'DWord' -or [int]$actual.Value -ne 3) {
                throw "Cannot verify $name=3; original settings are still backed up."
            }
        }
        Write-WinUtilLog -Component 'CPUMitigations' -Message 'CPU speculative-execution mitigations override set to 3/3. Windows restart required; security protection is reduced.'
        return
    }

    if (-not $backup) {
        throw 'No APBOptimizer CPU mitigation backup exists. Refusing to guess the original protection settings.'
    }
    foreach ($name in $names) {
        $previous = $backup.Values.PSObject.Properties[$name].Value
        if ($previous.Present) {
            $null = New-Item -Path $path -Force -ErrorAction Stop
            $null = New-ItemProperty -LiteralPath $path -Name $name -PropertyType DWord -Value ([int]$previous.Value) -Force -ErrorAction Stop
        } else {
            $current = Get-WinUtilCPUMitigationsRegistryValue -Path $path -Name $name
            if ($current.Present) {
                Remove-ItemProperty -LiteralPath $path -Name $name -ErrorAction Stop
            }
        }
    }
    foreach ($name in $names) {
        $previous = $backup.Values.PSObject.Properties[$name].Value
        $actual = Get-WinUtilCPUMitigationsRegistryValue -Path $path -Name $name
        if ($previous.Present) {
            if (-not $actual.Present -or $actual.Kind -ne 'DWord' -or [int]$actual.Value -ne [int]$previous.Value) {
                throw "Could not verify restoration of $name; backup retained."
            }
        } elseif ($actual.Present) {
            throw "Could not remove originally absent $name; backup retained."
        }
    }
    Remove-ItemProperty -LiteralPath $backupPath -Name Snapshot -ErrorAction Stop
    Write-WinUtilLog -Component 'CPUMitigations' -Message 'Original CPU mitigation registry values restored. Restart Windows for the changes to take effect.'
}

function Get-WinUtilDevicePowerSettingList {
    # Only the plugged-in (AC) index is changed; battery behavior stays as configured.
    @(
        [pscustomobject]@{ Name = 'USB selective suspend'; Subgroup = '2a737441-1930-4402-8d77-b2bebba308a3'; Setting = '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'; Max = 1 }
        [pscustomobject]@{ Name = 'PCI Express Link State Power Management'; Subgroup = '501a4d13-42af-4429-9fd1-a8218c268e20'; Setting = 'ee12f906-d277-404b-b6da-e5fa1a576df5'; Max = 2 }
    )
}

function Invoke-WinUtilPowerCfg {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $output = @(powercfg @Arguments)
    if ($LASTEXITCODE -ne 0) {
        throw "powercfg $($Arguments -join ' ') failed: $($output -join ' ')"
    }
    return $output
}

function Get-WinUtilActivePowerScheme {
    $output = Invoke-WinUtilPowerCfg -Arguments @('/getactivescheme')
    $match = [regex]::Match(($output -join ' '), '[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}')
    if (-not $match.Success) { throw 'Could not find the active power plan GUID.' }
    return $match.Value.ToLowerInvariant()
}

function Get-WinUtilPowerSettingAcValue {
    param([Parameter(Mandatory)][string]$Scheme, [Parameter(Mandatory)]$Setting)

    $output = Invoke-WinUtilPowerCfg -Arguments @('/query', $Scheme, $Setting.Subgroup, $Setting.Setting)
    # Labels are localized; the current AC and DC indexes are the only hex values.
    $values = @($output | ForEach-Object {
        if ([string]$_ -match ':\s*0x([0-9a-fA-F]+)\s*$') { [Convert]::ToInt32($Matches[1], 16) }
    })
    if ($values.Count -ne 2) { throw "$($Setting.Name) is not available in power plan $Scheme." }
    return $values[0]
}

function Get-WinUtilDevicePowerSavingBackup {
    $saved = Get-WinUtilPowerThrottlingRegistryValue -Path 'HKLM:\SOFTWARE\OptiUtil\DevicePowerSavingBackup' -Name Snapshot
    if (-not $saved.Present) { return $null }
    if ($saved.Kind -ne 'String' -or [string]::IsNullOrWhiteSpace([string]$saved.Value)) {
        throw 'Device power saving backup is empty or has an invalid type. No changes made.'
    }
    $backup = ConvertFrom-Json -InputObject ([string]$saved.Value) -ErrorAction Stop
    $known = @(Get-WinUtilDevicePowerSettingList)
    $entries = @($backup.Settings)
    $valid = $backup.Version -eq 1 -and [string]$backup.Scheme -match '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$' -and
        $entries.Count -eq $known.Count
    if ($valid) {
        foreach ($entry in $entries) {
            $setting = $known | Where-Object { $_.Setting -eq $entry.Setting }
            if (-not $setting -or [string]$entry.AC -notmatch '^\d+$' -or [int]$entry.AC -gt $setting.Max) { $valid = $false }
        }
    }
    if (-not $valid) { throw 'Unrecognized device power saving backup. No changes made.' }
    return $backup
}

function Set-WinUtilDevicePowerSaving {
    param([Parameter(Mandatory)][ValidateSet('Disable', 'Restore')][string]$Mode)

    if (-not (Test-WinUtilWindowsUpdateAdmin)) {
        throw 'Administrator privileges are required to change power plan settings.'
    }

    $backupPath = 'HKLM:\SOFTWARE\OptiUtil\DevicePowerSavingBackup'
    $settings = @(Get-WinUtilDevicePowerSettingList)
    $backup = Get-WinUtilDevicePowerSavingBackup
    if ($Mode -eq 'Disable') {
        $scheme = Get-WinUtilActivePowerScheme
        if ($backup -and $backup.Scheme -ne $scheme) {
            throw "Device power saving was already changed in power plan $($backup.Scheme). Undo it before applying to another plan."
        }
        if (-not $backup) {
            $backup = [pscustomobject]@{
                Version = 1
                Scheme = $scheme
                Settings = @($settings | ForEach-Object {
                    [pscustomobject]@{ Setting = $_.Setting; AC = [int](Get-WinUtilPowerSettingAcValue -Scheme $scheme -Setting $_) }
                })
            }
            # Save the plan's original AC indexes before modifying Windows.
            $null = New-Item -Path $backupPath -Force -ErrorAction Stop
            $null = New-ItemProperty -LiteralPath $backupPath -Name Snapshot -PropertyType String -Value ($backup | ConvertTo-Json -Depth 4 -Compress) -Force -ErrorAction Stop
        }
        foreach ($setting in $settings) {
            $null = Invoke-WinUtilPowerCfg -Arguments @('/setacvalueindex', $scheme, $setting.Subgroup, $setting.Setting, '0')
        }
        $null = Invoke-WinUtilPowerCfg -Arguments @('/setactive', $scheme)
        foreach ($setting in $settings) {
            if ((Get-WinUtilPowerSettingAcValue -Scheme $scheme -Setting $setting) -ne 0) {
                throw "Could not verify that $($setting.Name) is off; original values backed up for recovery."
            }
        }
        Write-WinUtilLog -Component 'DevicePowerSaving' -Message "USB selective suspend and PCIe link state power management turned off (AC) in power plan $scheme."
        return
    }

    if (-not $backup) {
        throw 'No device power saving backup exists. Refusing to guess the original power plan settings.'
    }
    $schemes = (Invoke-WinUtilPowerCfg -Arguments @('/list')) -join ' '
    if ($schemes -notmatch [regex]::Escape($backup.Scheme)) {
        # The plan was deleted together with its settings; nothing is left to restore.
        Remove-ItemProperty -LiteralPath $backupPath -Name Snapshot -ErrorAction Stop
        Write-WinUtilLog -Component 'DevicePowerSaving' -Level 'WARN' -Message "Power plan $($backup.Scheme) no longer exists; device power saving backup discarded."
        return
    }
    foreach ($entry in @($backup.Settings)) {
        $setting = $settings | Where-Object { $_.Setting -eq $entry.Setting }
        $null = Invoke-WinUtilPowerCfg -Arguments @('/setacvalueindex', $backup.Scheme, $setting.Subgroup, $setting.Setting, [string][int]$entry.AC)
    }
    if ((Get-WinUtilActivePowerScheme) -eq $backup.Scheme) {
        $null = Invoke-WinUtilPowerCfg -Arguments @('/setactive', $backup.Scheme)
    }
    foreach ($entry in @($backup.Settings)) {
        $setting = $settings | Where-Object { $_.Setting -eq $entry.Setting }
        if ((Get-WinUtilPowerSettingAcValue -Scheme $backup.Scheme -Setting $setting) -ne [int]$entry.AC) {
            throw "Original $($setting.Name) value could not be verified; backup retained."
        }
    }
    Remove-ItemProperty -LiteralPath $backupPath -Name Snapshot -ErrorAction Stop
    Write-WinUtilLog -Component 'DevicePowerSaving' -Message "Original USB selective suspend and PCIe link state values restored in power plan $($backup.Scheme)."
}

function Set-WinUtilDNS {
    <#

    .SYNOPSIS
        Sets the DNS of all interfaces that are in the "Up" state. It will lookup the values from the DNS.Json file

    .PARAMETER DNSProvider
        The DNS provider to set the DNS server to

    .EXAMPLE
        Set-WinUtilDNS -DNSProvider "google"

    #>
    param($DNSProvider)

    if($DNSProvider -eq "Default") {
        Write-WinUtilLog -Component "DNS" -Message "DNS provider is Default; no DNS changes applied."
        return $true
    }

    if($DNSProvider -eq "Fastest") {
        Write-WinUtilLog -Component "DNS" -Message "Auto-detecting fastest DNS provider via latency benchmark..."
        $benchmark = Get-WinUtilDNSBenchmark
        $validFastest = $benchmark | Where-Object { $_.LatencyMs -lt 9999 } | Select-Object -First 1
        if ($validFastest) {
            $DNSProvider = $validFastest.Provider
            Write-Host "Auto-selected fastest DNS provider: $DNSProvider ($($validFastest.LatencyMs) ms)"
            Write-WinUtilLog -Component "DNS" -Message "Auto-selected fastest DNS provider: $DNSProvider ($($validFastest.LatencyMs) ms)"
        } else {
            Write-Warning "Could not measure DNS latency to any provider; keeping current network adapter DNS settings."
            Write-WinUtilLog -Component "DNS" -Message "Benchmark timeout or all probes failed; aborting DNS change to preserve existing settings."
            return $false
        }
    }

    try {
        $Adapters = Get-NetAdapter | Where-Object {$_.Status -eq "Up"}
        Write-Host "Ensuring DNS is set to $DNSProvider on the following interfaces:"
        Write-Host $($Adapters | Out-String)
        Write-WinUtilLog -Component "DNS" -Message "Setting DNS provider to $DNSProvider for $(@($Adapters).Count) active adapter(s)."

        if($DNSProvider -ne "DHCP") {
            $dns = $sync.configs.dns.$DNSProvider
            if($null -eq $dns) {
                Write-Warning "DNS provider $DNSProvider was not found in configuration."
                Write-WinUtilLog -Level "ERROR" -Component "DNS" -Message "DNS provider $DNSProvider was not found in configuration."
                return $false
            }
        }

        $dohSupported = [bool](Get-Command Add-DnsClientDohServerAddress -ErrorAction SilentlyContinue)
        if ($DNSProvider -ne "DHCP" -and $dns.DohOnly -and -not $dohSupported) {
            Write-Warning "DNS provider $DNSProvider requires DNS over HTTPS, which is not supported on this system."
            Write-WinUtilLog -Level "ERROR" -Component "DNS" -Message "DNS provider $DNSProvider requires DNS over HTTPS, which is not supported on this system."
            return $false
        }

        $dnscacheBase = "HKLM:\System\CurrentControlSet\Services\Dnscache\InterfaceSpecificParameters"

        Foreach ($Adapter in $Adapters) {
            $interfaceParams = "$dnscacheBase\$($Adapter.InterfaceGuid)"

            if($DNSProvider -eq "DHCP") {
                Write-WinUtilLog -Component "DNS" -Message "Resetting DNS to DHCP on adapter $($Adapter.Name) (ifIndex: $($Adapter.ifIndex))."
                Set-DnsClientServerAddress -InterfaceIndex $Adapter.ifIndex -ResetServerAddresses
                netsh interface ip set dnsservers name="$($Adapter.Name)" source=dhcp
                netsh interface ipv6 set dnsservers name="$($Adapter.Name)" source=dhcp

                $dohInterfaceSettings = "$interfaceParams\DohInterfaceSettings"
                if (Test-Path $dohInterfaceSettings) {
                    if ($dohSupported) {
                        $dohServerAddresses = @(
                            Get-ChildItem -Path "$dohInterfaceSettings\Doh" -ErrorAction SilentlyContinue
                            Get-ChildItem -Path "$dohInterfaceSettings\Doh6" -ErrorAction SilentlyContinue
                        ) | Select-Object -ExpandProperty PSChildName -Unique

                        foreach ($ip in $dohServerAddresses) {
                            if (Get-DnsClientDohServerAddress -ServerAddress $ip -ErrorAction SilentlyContinue) {
                                Write-WinUtilLog -Component "DNS" -Message "Removing DoH registration for $ip."
                                Remove-DnsClientDohServerAddress -ServerAddress $ip -Confirm:$false -ErrorAction Stop
                            }
                        }
                    }

                    Remove-Item -Path $dohInterfaceSettings -Recurse -Force -ErrorAction SilentlyContinue
                }
            } else {
                $ipv4Addresses = @(@($dns.Primary, $dns.Secondary) | Where-Object { $_ })
                $ipv6Addresses = @(@($dns.Primary6, $dns.Secondary6) | Where-Object { $_ })

                if ($dohSupported -and $dns.DohTemplate) {
                    try {
                        $ips = @($dns.Primary, $dns.Secondary, $dns.Primary6, $dns.Secondary6) | Where-Object { $_ }
                        foreach ($ip in $ips) {
                            $dohTemplate = if ($dns.SecondaryDohTemplate -and @($dns.Secondary, $dns.Secondary6) -contains $ip) {
                                $dns.SecondaryDohTemplate
                            } else {
                                $dns.DohTemplate
                            }
                            $existing = Get-DnsClientDohServerAddress -ServerAddress $ip -ErrorAction SilentlyContinue
                            if ($existing) {
                                Set-DnsClientDohServerAddress -ServerAddress $ip -DohTemplate $dohTemplate -AllowFallbackToUdp $false -AutoUpgrade $true -ErrorAction Stop
                            } else {
                                Write-WinUtilLog -Component "DNS" -Message "Registering DoH template for $ip."
                                Add-DnsClientDohServerAddress -ServerAddress $ip -DohTemplate $dohTemplate -AllowFallbackToUdp $false -AutoUpgrade $true -ErrorAction Stop
                            }

                            $leaf = if ($ip.Contains(':')) { 'Doh6' } else { 'Doh' }
                            $regPath = "$interfaceParams\DohInterfaceSettings\$leaf\$ip"

                            if (-not (Test-Path $regPath)) {
                                New-Item -Path $regPath -Force -ErrorAction Stop | Out-Null
                            }
                            New-ItemProperty -Path $regPath -Name "DohFlags" -Value 1 -PropertyType QWord -Force -ErrorAction Stop | Out-Null
                        }
                    } catch {
                        if ($dns.DohOnly) {
                            throw
                        }

                        Write-Warning "DNS over HTTPS setup for provider $DNSProvider failed; continuing with plain DNS."
                        Write-WinUtilLog -Level "WARN" -Component "DNS" -Message "DNS over HTTPS setup for provider $DNSProvider failed; continuing with plain DNS: $($psitem.Exception.Message)"
                    }
                }

                Write-WinUtilLog -Component "DNS" -Message "Setting IPv4 DNS on adapter $($Adapter.Name) (ifIndex: $($Adapter.ifIndex)) to $($dns.Primary), $($dns.Secondary)."
                Set-DnsClientServerAddress -InterfaceIndex $Adapter.ifIndex -ServerAddresses $ipv4Addresses -ErrorAction Stop
                Write-WinUtilLog -Component "DNS" -Message "Setting IPv6 DNS on adapter $($Adapter.Name) (ifIndex: $($Adapter.ifIndex)) to $($dns.Primary6), $($dns.Secondary6)."
                Set-DnsClientServerAddress -InterfaceIndex $Adapter.ifIndex -ServerAddresses $ipv6Addresses -ErrorAction Stop
            }
        }
        if ($DNSProvider -ne "DHCP" -and $dohSupported -and $dns.DohTemplate) {
            Clear-DnsClientCache
        }
        Write-WinUtilLog -Component "DNS" -Message "DNS provider change completed: $DNSProvider"
        return $true
    } catch {
        Write-Warning "DNS provider $DNSProvider was not completed because an error occurred."
        Write-Warning $psitem.Exception.Message
        Write-WinUtilLog -Level "ERROR" -Component "DNS" -Message "DNS provider $DNSProvider was not completed: $($psitem.Exception.Message)"
        return $false
    }
}

function Get-WinUtilSystemLanguage {
    param([string]$CultureName = [Globalization.CultureInfo]::CurrentUICulture.Name)

    # Windows UI culture, not the keyboard layout or the region.
    if ([string]$CultureName -match '^es(?:-|$)') { return 'es' }
    return 'en'
}

function Initialize-WinUtilLanguage {
    # Keep fork preferences independent from the original WinUtil's data.
    $configFolder = if ($sync.LanguageConfigDir) { $sync.LanguageConfigDir } else {
        Join-Path $env:LOCALAPPDATA 'APBOptimizer'
    }
    $sync.LanguageSettingsPath = Join-Path $configFolder 'settings.json'
    $choice = 'auto'
    try {
        $settingsToRead = $sync.LanguageSettingsPath
        # Preserve the previous name's language preference on the first launch.
        # An explicit test/config directory must never read from real AppData.
        if (-not $sync.LanguageConfigDir -and -not (Test-Path -LiteralPath $settingsToRead)) {
            $legacySettings = Join-Path (Join-Path $env:LOCALAPPDATA 'OptiUtil') 'settings.json'
            if (Test-Path -LiteralPath $legacySettings) {
                $settingsToRead = $legacySettings
            }
        }
        if (Test-Path -LiteralPath $settingsToRead) {
            $stored = Get-Content -LiteralPath $settingsToRead -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($stored.language -in @('auto', 'es', 'en')) {
                $choice = [string]$stored.language
            }
        }
    } catch {
        Write-Warning "Could not read APBOptimizer language preference: $($_.Exception.Message)"
    }
    $sync.preferences.language = $choice
    $sync.Language = if ($choice -eq 'auto') { Get-WinUtilSystemLanguage } else { $choice }
}

function Get-WinUtilLocalizedEntry {
    param([Parameter(Mandatory)][string]$Key)
    if ($sync.Language -ne 'es' -or $null -eq $sync.configs.es) { return $null }
    return $sync.configs.es.PSObject.Properties[$Key].Value
}

function Get-WinUtilLocalizedCategory {
    param([Parameter(Mandatory)][string]$Category)
    if ($sync.Language -eq 'es' -and $null -ne $sync.configs.es) {
        $translated = $sync.configs.es.Categories.PSObject.Properties[$Category]
        if ($translated -and $translated.Value) { return [string]$translated.Value }
    }
    return $Category
}

function Update-WinUtilLanguageUI {
    if ($null -eq $sync.Form) { return }
    if ($null -eq $sync.LanguageOriginalUI) { $sync.LanguageOriginalUI = @{} }
    $translations = $sync.configs.localization
    if ($null -eq $translations) { return }
    $english = $translations.en
    $spanish = $translations.es
    $keys = @($english.PSObject.Properties.Name) + @($spanish.PSObject.Properties.Name) | Select-Object -Unique

    foreach ($name in $keys) {
        $control = $sync[$name]
        if ($null -eq $control) { continue }
        $fields = @{}
        foreach ($culture in @($english, $spanish)) {
            $translatedControl = $culture.PSObject.Properties[$name]
            if ($null -eq $translatedControl) { continue }
            foreach ($field in $translatedControl.Value.PSObject.Properties.Name) { $fields[$field] = $true }
        }
        foreach ($field in $fields.Keys) {
            $originalKey = "$name/$field"
            if (-not $sync.LanguageOriginalUI.ContainsKey($originalKey)) {
                $sync.LanguageOriginalUI[$originalKey] = $control.$field
            }
            $translation = $translations.$($sync.Language).PSObject.Properties[$name]
            $value = if ($translation -and $translation.Value.PSObject.Properties[$field]) {
                $translation.Value.$field
            } else { $sync.LanguageOriginalUI[$originalKey] }
            # Fix legacy text decoded as ANSI by Windows PowerShell 5.1.
            # XAML objects and correctly decoded JSON are left untouched.
            $control.$field = Convert-WinUtilTextEncoding -Text $value
        }
    }
    if ($null -ne $sync.WPFLanguageSelector) {
        $sync.LanguageSelectorChanging = $true
        try {
            foreach ($option in $sync.WPFLanguageSelector.Items) {
                if ($option.Tag -eq 'auto') {
                    $option.Content = if ($sync.Language -eq 'es') { 'Automático (Windows)' } else { 'Automatic (Windows)' }
                }
                if ($option.Tag -eq $sync.preferences.language) {
                    $sync.WPFLanguageSelector.SelectedItem = $option
                }
            }
        } finally { $sync.LanguageSelectorChanging = $false }
    }
}

function Set-WinUtilLanguage {
    param(
        [Parameter(Mandatory)][ValidateSet('auto', 'es', 'en')][string]$Language,
        [switch]$SkipSave
    )

    $previous = $sync.Language
    $sync.preferences.language = $Language
    $sync.Language = if ($Language -eq 'auto') { Get-WinUtilSystemLanguage } else { $Language }

    if (-not $SkipSave) {
        try {
            $parent = Split-Path -Parent $sync.LanguageSettingsPath
            if (-not (Test-Path -LiteralPath $parent)) {
                New-Item -ItemType Directory -Path $parent -Force | Out-Null
            }
            @{ language = $Language } | ConvertTo-Json -Compress |
                Set-Content -LiteralPath $sync.LanguageSettingsPath -Encoding UTF8 -ErrorAction Stop
        } catch {
            Write-Warning "Could not save APBOptimizer language preference: $($_.Exception.Message)"
        }
    }

    Update-WinUtilLanguageUI
    if ($sync.currentTab -eq 'Advanced') {
        Update-WinUtilWindowsUpdateStatusUI
    }

    # Rebuild only the localized labels, never the underlying tweak configuration.
    # Imported/selected checkboxes are restored while toggle handlers are in import
    # mode, so changing language cannot modify services or registry values.
    if ($previous -ne $sync.Language -and $sync.InitializedTabs -and $sync.InitializedTabs['Tweaks']) {
        $wasImporting = $sync.ImportInProgress
        $sync.ImportInProgress = $true
        try {
            Invoke-WPFUIElements -configVariable $sync.configs.tweaks -targetGridName 'tweakspanel' -columncount 2
            Reset-WPFCheckBoxes -doToggles $true
            Find-TweaksByNameOrDescription -SearchString $sync.SearchBar.Text
        } finally { $sync.ImportInProgress = $wasImporting }
    }
}

function Get-WinUtilMemoryIntegrityRegistryValue {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name
    )
    $result = [pscustomobject]@{ Present = $false; Kind = ''; Value = $null }
    try {
        $key = Get-Item -LiteralPath $Path -ErrorAction Stop
    } catch {
        # A missing registry key is fine. Denied access, a broken provider,
        # or other read errors must NOT look like a nonexistent policy/lock.
        if ($_.Exception -is [System.Management.Automation.ItemNotFoundException] -or
            $_.FullyQualifiedErrorId -like 'PathNotFound,*' -or
            $_.FullyQualifiedErrorId -like 'ItemNotFound,*') {
            return $result
        }
        throw
    }
    if ($null -eq $key -or $Name -notin @($key.GetValueNames())) { return $result }
    $result.Present = $true
    $result.Kind = [string]$key.GetValueKind($Name)
    $result.Value = $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    return $result
}

function Get-WinUtilMemoryIntegrityBackup {
    $path = 'HKLM:\SOFTWARE\OptiUtil\MemoryIntegrityBackup'
    $saved = Get-WinUtilMemoryIntegrityRegistryValue -Path $path -Name Snapshot
    if (-not $saved.Present) { return $null }
    if ($saved.Kind -ne 'String' -or [string]::IsNullOrWhiteSpace([string]$saved.Value)) {
        throw 'HVCI backup exists but is empty. Refusing to overwrite its recovery information.'
    }
    $snapshot = ConvertFrom-Json -InputObject ([string]$saved.Value) -ErrorAction Stop
    if ($snapshot.Version -ne 1 -or $snapshot.HadEnabled -isnot [bool] -or
        ($snapshot.HadEnabled -and ($snapshot.Kind -ne 'DWord' -or
            $null -eq $snapshot.EnabledValue -or
            [string]$snapshot.EnabledValue -notmatch '^-?\d+$'))) {
        throw 'Unrecognized HVCI backup; refusing to change memory integrity.'
    }
    return $snapshot
}

function Assert-WinUtilMemoryIntegrityIsConfigurable {
    # Enabling/disabling a UEFI-locked or policy-managed HVCI installation
    # requires its management authority. Never overwrite those settings.
    $deviceGuard = 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard'
    $scenario = "$deviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity"
    foreach ($path in @($deviceGuard, $scenario)) {
        $locked = Get-WinUtilMemoryIntegrityRegistryValue -Path $path -Name Locked
        if ($locked.Present -and [string]$locked.Value -ne '0') {
            throw 'HVCI/DeviceGuard has a UEFI lock. Change it through the authorized firmware/policy procedure instead.'
        }
    }
    $policy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceGuard'
    $policyValue = Get-WinUtilMemoryIntegrityRegistryValue -Path $policy -Name HypervisorEnforcedCodeIntegrity
    if ($policyValue.Present) {
        throw 'Memory integrity is configured by Group Policy; change the managed policy rather than overriding it.'
    }
}

function Set-WinUtilMemoryIntegrity {
    param([Parameter(Mandatory)][ValidateSet('Disable', 'Restore')][string]$Mode)

    if ([Environment]::OSVersion.Version.Major -lt 10) {
        throw 'Memory integrity (HVCI) setting is only supported here on Windows 10/11.'
    }
    if (-not (Test-WinUtilWindowsUpdateAdmin)) {
        throw 'Administrator privileges are required to change memory integrity.'
    }
    Assert-WinUtilMemoryIntegrityIsConfigurable

    $scenario = 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity'
    $backupPath = 'HKLM:\SOFTWARE\OptiUtil\MemoryIntegrityBackup'
    $backup = Get-WinUtilMemoryIntegrityBackup

    if ($Mode -eq 'Disable') {
        $previous = Get-WinUtilMemoryIntegrityRegistryValue -Path $scenario -Name Enabled
        if ($previous.Present -and $previous.Kind -ne 'DWord') {
            throw 'Unexpected HVCI Enabled value type: refusing to overwrite it.'
        }
        if (-not $backup) {
            $backup = [pscustomobject]@{
                Version = 1
                HadEnabled = [bool]$previous.Present
                Kind = if ($previous.Present) { 'DWord' } else { '' }
                EnabledValue = if ($previous.Present) { [int]$previous.Value } else { $null }
            }
            # Save the original value (or absence) BEFORE writing Enabled=0.
            $null = New-Item -Path $backupPath -Force -ErrorAction Stop
            $null = New-ItemProperty -LiteralPath $backupPath -Name Snapshot -PropertyType String -Value ($backup | ConvertTo-Json -Depth 4 -Compress) -Force -ErrorAction Stop
        }
        $null = New-Item -Path $scenario -Force -ErrorAction Stop
        $null = New-ItemProperty -LiteralPath $scenario -Name Enabled -PropertyType DWord -Value 0 -Force -ErrorAction Stop
        $after = Get-WinUtilMemoryIntegrityRegistryValue -Path $scenario -Name Enabled
        if (-not $after.Present -or $after.Kind -ne 'DWord' -or [int]$after.Value -ne 0) {
            throw 'HVCI Enabled=0 could not be verified. Original settings remain backed up.'
        }
        Write-WinUtilLog -Component 'MemoryIntegrity' -Message 'Memory integrity Enabled=0 saved. Restart Windows to request HVCI disable. VBS and other policies unchanged.'
        return
    }

    if (-not $backup) {
        throw 'No APBOptimizer HVCI backup exists. Refusing to guess the previous protection state.'
    }
    if ($backup.HadEnabled) {
        $null = New-Item -Path $scenario -Force -ErrorAction Stop
        $null = New-ItemProperty -LiteralPath $scenario -Name Enabled -PropertyType DWord -Value ([int]$backup.EnabledValue) -Force -ErrorAction Stop
    } else {
        $now = Get-WinUtilMemoryIntegrityRegistryValue -Path $scenario -Name Enabled
        if ($now.Present) {
            Remove-ItemProperty -LiteralPath $scenario -Name Enabled -ErrorAction Stop
        }
    }
    $after = Get-WinUtilMemoryIntegrityRegistryValue -Path $scenario -Name Enabled
    if ($backup.HadEnabled) {
        if (-not $after.Present -or $after.Kind -ne 'DWord' -or
            [int]$after.Value -ne [int]$backup.EnabledValue) {
            throw 'Could not verify original HVCI state after Restore. Backup retained.'
        }
    } elseif ($after.Present) {
        throw 'Could not remove the originally absent HVCI Enabled value. Backup retained.'
    }
    Remove-ItemProperty -LiteralPath $backupPath -Name Snapshot -ErrorAction Stop
    Write-WinUtilLog -Component 'MemoryIntegrity' -Message 'Original HVCI Enabled registry state restored. Restart Windows; other VBS settings unchanged.'
}

function Get-WinUtilOptionalDriverNames {
    # Explicit allowlist. Never accept an arbitrary kernel driver name.
    return @('Telemetry', 'PEAUTH', 'tcpipreg', 'IntelPMT', 'GpuEnergyDrv', 'IObitUnlocker', 'UCPD')
}

function Get-WinUtilUcpdTask {
    # UCPD's scheduled task can reconfigure the driver on logon. Only manage
    # this one exact task, not the other AppxDeploymentClient tasks.
    if (-not (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue)) {
        throw 'Task Scheduler PowerShell support is unavailable; UCPD startup cannot be managed safely.'
    }
    return Get-ScheduledTask -ErrorAction Stop |
        Where-Object {
            $_.TaskName -eq 'UCPD velocity' -and
            $_.TaskPath -eq '\Microsoft\Windows\AppxDeploymentClient\'
        } | Select-Object -First 1
}

function Get-WinUtilOptionalDriverBackup {
    param([Parameter(Mandatory)][string]$Name)
    $saved = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\OptiUtil\DriverStartupBackup' -Name $Name -ErrorAction SilentlyContinue
    if (-not $saved) { return $null }
    $serialized = [string]$saved.$Name
    if ([string]::IsNullOrWhiteSpace($serialized)) { return $null }
    $backup = ConvertFrom-Json -InputObject $serialized -ErrorAction Stop
    if ($backup.Version -ne 1 -or $backup.Name -ne $Name -or
        $backup.Start -notin $(if ($Name -eq 'UCPD') { @(1, 2, 3) } else { @(2, 3) }) -or
        ($Name -eq 'UCPD' -and
            (@($backup.PSObject.Properties.Name) -notcontains 'TaskPresent' -or
             @($backup.PSObject.Properties.Name) -notcontains 'TaskEnabled'))) {
        throw "Unrecognized saved driver configuration for $Name. No changes were made."
    }
    return $backup
}

function Get-WinUtilOptionalDriverInfo {
    param([Parameter(Mandatory)][string]$Name)
    if ($Name -notin (Get-WinUtilOptionalDriverNames)) { throw "Driver $Name is not approved for optional management." }
    $info = [pscustomobject]@{
        Name = $Name; Present = $false; CanChange = $false; Disabled = $false
        Managed = $false; Start = $null; Type = $null; ImagePath = ''; Reason = 'Not installed'
    }
    $path = "HKLM:\SYSTEM\CurrentControlSet\Services\$Name"
    $entry = Get-ItemProperty -LiteralPath $path -ErrorAction SilentlyContinue
    if (-not $entry -or $null -eq $entry.Start -or $null -eq $entry.Type) { return $info }
    $info.Present = $true
    $info.Start = [int]$entry.Start
    $info.Type = [int]$entry.Type
    $info.ImagePath = [string]$entry.ImagePath
    # Disabled is the actual driver startup state. Even if APBOptimizer cannot
    # restore an unmanaged Start=4 driver, it must show as already disabled
    # rather than an unchecked (apparently active) switch.
    $info.Disabled = ($info.Start -eq 4)

    if ($info.Type -notin @(1, 2)) { $info.Reason = 'Not a kernel or file-system driver'; return $info }
    if ($info.Start -eq 0 -or ($info.Start -eq 1 -and $Name -ne 'UCPD')) {
        $info.Reason = 'Boot/System startup: protected'
        return $info
    }
    if ($Name -eq 'UCPD' -and ($info.Type -ne 2 -or $info.ImagePath -notmatch '(?i)(^|[\\/])UCPD\.sys$')) {
        $info.Reason = 'UCPD driver identity does not match the expected UCPD.sys filter driver'
        return $info
    }
    if ($null -ne $entry.ErrorControl -and [int]$entry.ErrorControl -ge 2) {
        $info.Reason = 'Severe/Critical boot error handling: protected'
        return $info
    }

    $backup = Get-WinUtilOptionalDriverBackup -Name $Name
    if ($backup -and ($backup.Type -ne $info.Type -or $backup.ImagePath -ne $info.ImagePath)) {
        $info.Reason = 'Driver identity changed since backup: review manually'
        return $info
    }
    $info.Managed = [bool]$backup
    if ($info.Start -eq 4 -and -not $info.Managed) {
        $info.Reason = 'Already disabled outside APBOptimizer; no original state to restore'
        return $info
    }
    if ($info.Start -notin $(if ($Name -eq 'UCPD') { @(1, 2, 3, 4) } else { @(2, 3, 4) })) {
        $info.Reason = 'Unsupported startup value'
        return $info
    }
    $info.CanChange = $true
    if ($Name -eq 'UCPD') {
        try {
            $task = Get-WinUtilUcpdTask
            if ($task -and $task.State -ne 'Disabled') { $info.Disabled = $false }
        } catch {
            $info.CanChange = $false
            $info.Disabled = $false
            $info.Reason = "Cannot inspect UCPD velocity task: $($_.Exception.Message)"
            return $info
        }
    }
    $info.Reason = if ($info.Disabled) { 'Disabled by APBOptimizer (takes effect after reboot)' } else { 'Optional driver; reboot needed after change' }
    return $info
}

function Set-WinUtilOptionalDriverStartup {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet(1, 2, 3, 4)][int]$Start
    )
    if ($Start -eq 1 -and $Name -ne 'UCPD') { throw "System-start is only permitted for restoring the UCPD driver." }
    $mode = @{ 1 = 'system'; 2 = 'auto'; 3 = 'demand'; 4 = 'disabled' }[$Start]
    $output = & sc.exe config $Name 'start=' $mode 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Service Control Manager refused to configure driver $Name ($LASTEXITCODE): $($output -join ' ')"
    }
}

function Set-WinUtilOptionalDriver {
    param(
        [Parameter(Mandatory)][ValidateSet('Telemetry', 'PEAUTH', 'tcpipreg', 'IntelPMT', 'GpuEnergyDrv', 'IObitUnlocker', 'UCPD')][string]$Name,
        [Parameter(Mandatory)][ValidateSet('Disable', 'Restore')][string]$Mode
    )
    if (-not (Test-WinUtilWindowsUpdateAdmin)) { throw 'Administrator privileges required to change driver startup.' }
    $info = Get-WinUtilOptionalDriverInfo -Name $Name
    if (-not $info.Present) {
        Write-WinUtilLog -Component 'Drivers' -Message "Driver $Name is not installed. Skipping."
        return
    }
    if (-not $info.CanChange) { throw "Driver $Name cannot be changed: $($info.Reason)" }

    $backupPath = 'HKLM:\SOFTWARE\OptiUtil\DriverStartupBackup'
    $servicePath = "HKLM:\SYSTEM\CurrentControlSet\Services\$Name"
    if ($Mode -eq 'Disable') {
        if ($info.Disabled) { return }
        $existing = Get-WinUtilOptionalDriverBackup -Name $Name
        if (-not $existing) {
            $ucpdTask = if ($Name -eq 'UCPD') { Get-WinUtilUcpdTask } else { $null }
            $existing = [pscustomobject]@{
                Version = 1; Name = $Name; Start = $info.Start
                Type = $info.Type; ImagePath = $info.ImagePath
            }
            if ($Name -eq 'UCPD') {
                $existing | Add-Member -NotePropertyName TaskPresent -NotePropertyValue ([bool]$ucpdTask)
                $existing | Add-Member -NotePropertyName TaskEnabled -NotePropertyValue ([bool]($ucpdTask -and $ucpdTask.State -ne 'Disabled'))
            }
            # Save first. Never infer an original startup value during Undo.
            $null = New-Item -Path $backupPath -Force -ErrorAction Stop
            $null = New-ItemProperty -LiteralPath $backupPath -Name $Name -PropertyType String -Value ($existing | ConvertTo-Json -Depth 4 -Compress) -Force -ErrorAction Stop
        }
        $target = 4
    } else {
        $existing = Get-WinUtilOptionalDriverBackup -Name $Name
        if (-not $existing) { throw "No APBOptimizer backup exists for $Name; refusing to invent its previous startup configuration." }
        $target = [int]$existing.Start
    }

    if ($Name -eq 'UCPD' -and $Mode -eq 'Disable') {
        $task = Get-WinUtilUcpdTask
        if ($task -and $task.State -ne 'Disabled') {
            $null = Disable-ScheduledTask -TaskName 'UCPD velocity' -TaskPath '\Microsoft\Windows\AppxDeploymentClient\' -ErrorAction Stop
        }
        $task = Get-WinUtilUcpdTask
        if ($task -and $task.State -ne 'Disabled') {
            throw 'UCPD velocity task is still enabled. Original startup backup retained.'
        }
    }

    # Driver binaries, device bindings, ACLs and loaded kernel modules remain
    # untouched. Only driver startup and the exact UCPD velocity task are managed.
    Set-WinUtilOptionalDriverStartup -Name $Name -Start $target
    $current = Get-ItemProperty -LiteralPath $servicePath -ErrorAction Stop
    if ([int]$current.Start -ne $target) {
        throw "Driver $Name startup change could not be verified. Backup preserved."
    }

    if ($Name -eq 'UCPD' -and $Mode -eq 'Restore') {
        $task = Get-WinUtilUcpdTask
        if ($existing.TaskPresent -and -not $task) {
            throw 'UCPD velocity task was present originally but is now missing. The recovery backup was preserved.'
        }
        if ($existing.TaskPresent) {
            $shouldEnable = [bool]$existing.TaskEnabled
            if ($shouldEnable -and $task.State -eq 'Disabled') {
                $null = Enable-ScheduledTask -TaskName 'UCPD velocity' -TaskPath '\Microsoft\Windows\AppxDeploymentClient\' -ErrorAction Stop
            } elseif (-not $shouldEnable -and $task.State -ne 'Disabled') {
                $null = Disable-ScheduledTask -TaskName 'UCPD velocity' -TaskPath '\Microsoft\Windows\AppxDeploymentClient\' -ErrorAction Stop
            }
            $task = Get-WinUtilUcpdTask
            if (-not $task -or (($task.State -ne 'Disabled') -ne $shouldEnable)) {
                throw 'UCPD velocity task could not be verified after restoration. Backup retained.'
            }
        }
    }

    if ($Mode -eq 'Restore') {
        Remove-ItemProperty -LiteralPath $backupPath -Name $Name -ErrorAction Stop
    }
    Write-WinUtilLog -Component 'Drivers' -Message "$Mode $Name startup verified. Restart Windows to apply driver load changes."
}

function Get-WinUtilPowerThrottlingRegistryValue {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name)

    $result = [pscustomobject]@{ Present = $false; Kind = ''; Value = $null }
    try {
        $key = Get-Item -LiteralPath $Path -ErrorAction Stop
    } catch {
        if ($_.Exception -is [System.Management.Automation.ItemNotFoundException] -or
            $_.FullyQualifiedErrorId -like 'PathNotFound,*' -or
            $_.FullyQualifiedErrorId -like 'ItemNotFound,*') {
            return $result
        }
        throw
    }
    if ($null -eq $key -or $Name -notin @($key.GetValueNames())) { return $result }
    $result.Present = $true
    $result.Kind = [string]$key.GetValueKind($Name)
    $result.Value = $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    return $result
}

function Get-WinUtilPowerThrottlingBackup {
    $saved = Get-WinUtilPowerThrottlingRegistryValue -Path 'HKLM:\SOFTWARE\OptiUtil\PowerThrottlingBackup' -Name Snapshot
    if (-not $saved.Present) { return $null }
    if ($saved.Kind -ne 'String' -or [string]::IsNullOrWhiteSpace([string]$saved.Value)) {
        throw 'Power Throttling backup is empty or has an invalid type. No changes made.'
    }
    $backup = ConvertFrom-Json -InputObject ([string]$saved.Value) -ErrorAction Stop
    if ($backup.Version -ne 1 -or $backup.HadValue -isnot [bool] -or
        ($backup.HadValue -and ($backup.Kind -ne 'DWord' -or $null -eq $backup.Value -or
            [string]$backup.Value -notmatch '^-?\d+$'))) {
        throw 'Unrecognized Power Throttling backup. No changes made.'
    }
    return $backup
}

function Set-WinUtilPowerThrottling {
    param([Parameter(Mandatory)][ValidateSet('Disable', 'Restore')][string]$Mode)

    if ([Environment]::OSVersion.Version.Major -lt 10) {
        throw 'Power Throttling control requires Windows 10 or newer.'
    }
    if (-not (Test-WinUtilWindowsUpdateAdmin)) {
        throw 'Administrator privileges are required to configure Power Throttling.'
    }

    $path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling'
    $backupPath = 'HKLM:\SOFTWARE\OptiUtil\PowerThrottlingBackup'
    $backup = Get-WinUtilPowerThrottlingBackup
    if ($Mode -eq 'Disable') {
        $previous = Get-WinUtilPowerThrottlingRegistryValue -Path $path -Name PowerThrottlingOff
        if ($previous.Present -and $previous.Kind -ne 'DWord') {
            throw 'Unexpected PowerThrottlingOff registry type: refusing to overwrite it.'
        }
        if (-not $backup) {
            $backup = [pscustomobject]@{
                Version = 1
                HadValue = [bool]$previous.Present
                Kind = if ($previous.Present) { 'DWord' } else { '' }
                Value = if ($previous.Present) { [int]$previous.Value } else { $null }
            }
            # Save the previous DWORD (or absence) before modifying Windows.
            $null = New-Item -Path $backupPath -Force -ErrorAction Stop
            $null = New-ItemProperty -LiteralPath $backupPath -Name Snapshot -PropertyType String -Value ($backup | ConvertTo-Json -Depth 4 -Compress) -Force -ErrorAction Stop
        }
        $null = New-Item -Path $path -Force -ErrorAction Stop
        $null = New-ItemProperty -LiteralPath $path -Name PowerThrottlingOff -PropertyType DWord -Value 1 -Force -ErrorAction Stop
        $actual = Get-WinUtilPowerThrottlingRegistryValue -Path $path -Name PowerThrottlingOff
        if (-not $actual.Present -or $actual.Kind -ne 'DWord' -or [int]$actual.Value -ne 1) {
            throw 'Could not verify PowerThrottlingOff=1; original value backed up for recovery.'
        }
        Write-WinUtilLog -Component 'PowerThrottling' -Message 'PowerThrottlingOff=1 applied. Power usage/temperature may increase; restart recommended.'
        return
    }

    if (-not $backup) {
        throw 'No Power Throttling backup exists. Refusing to guess the original power settings.'
    }
    if ($backup.HadValue) {
        $null = New-Item -Path $path -Force -ErrorAction Stop
        $null = New-ItemProperty -LiteralPath $path -Name PowerThrottlingOff -PropertyType DWord -Value ([int]$backup.Value) -Force -ErrorAction Stop
    } else {
        $current = Get-WinUtilPowerThrottlingRegistryValue -Path $path -Name PowerThrottlingOff
        if ($current.Present) {
            Remove-ItemProperty -LiteralPath $path -Name PowerThrottlingOff -ErrorAction Stop
        }
    }
    $actual = Get-WinUtilPowerThrottlingRegistryValue -Path $path -Name PowerThrottlingOff
    if ($backup.HadValue) {
        if (-not $actual.Present -or $actual.Kind -ne 'DWord' -or [int]$actual.Value -ne [int]$backup.Value) {
            throw 'Original Power Throttling DWORD could not be verified; backup retained.'
        }
    } elseif ($actual.Present) {
        throw 'Originally absent PowerThrottlingOff could not be removed; backup retained.'
    }
    Remove-ItemProperty -LiteralPath $backupPath -Name Snapshot -ErrorAction Stop
    Write-WinUtilLog -Component 'PowerThrottling' -Message 'Original Power Throttling registry value restored. Restart recommended.'
}

function Set-WinUtilRegistry {
    <#

    .SYNOPSIS
        Modifies the registry based on the given inputs

    .PARAMETER Name
        The name of the key to modify

    .PARAMETER Path
        The path to the key

    .PARAMETER Type
        The type of value to set the key to

    .PARAMETER Value
        The value to set the key to

    .EXAMPLE
        Set-WinUtilRegistry -Name "PublishUserActivities" -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Type "DWord" -Value "0"

    #>
    param (
        $Name,
        $Path,
        $Type,
        $Value
    )

    try {
        if(!(Test-Path 'HKU:\')) {New-PSDrive -PSProvider Registry -Name HKU -Root HKEY_USERS | Out-Null}

        If (!(Test-Path $Path)) {
            Write-Host "$Path was not found. Creating..."
            Write-WinUtilLog -Component "Registry" -Message "Creating registry path: $Path"
            New-Item -Path $Path -Force -ErrorAction Stop | Out-Null
        }

        if ($Value -ne "<RemoveEntry>") {
            Write-Host "Set $Path\$Name to $Value"
            Write-WinUtilLog -Component "Registry" -Message "Setting $Path\$Name ($Type) to $Value"
            Set-ItemProperty -Path $Path -Name $Name -Type $Type -Value $Value -Force -ErrorAction Stop | Out-Null
        }
        else{
            Write-Host "Remove $Path\$Name"
            Write-WinUtilLog -Component "Registry" -Message "Removing $Path\$Name"
            Remove-ItemProperty -Path $Path -Name $Name -Force -ErrorAction Stop | Out-Null
        }
    } catch [System.Security.SecurityException] {
        Write-Warning "Unable to set $Path\$Name to $Value due to a Security Exception."
        Write-WinUtilLog -Level "ERROR" -Component "Registry" -Message "Security exception while changing $Path\$Name to $Value`: $($psitem.Exception.Message)"
    } catch [System.Management.Automation.ItemNotFoundException] {
        Write-Warning $psitem.Exception.ErrorRecord
        Write-WinUtilLog -Level "ERROR" -Component "Registry" -Message "Registry item not found while changing $Path\$Name`: $($psitem.Exception.Message)"
    } catch [System.UnauthorizedAccessException] {
       Write-Warning $psitem.Exception.Message
       Write-WinUtilLog -Level "ERROR" -Component "Registry" -Message "Unauthorized while changing $Path\$Name`: $($psitem.Exception.Message)"
    } catch {
        Write-Warning "Unable to set $Name due to unhandled exception."
        Write-Warning $psitem.Exception.StackTrace
        Write-WinUtilLog -Level "ERROR" -Component "Registry" -Message "Unhandled exception while changing $Path\$Name`: $($psitem.Exception.Message)"
    }
}

function Set-WinUtilRegistryComboState {
    <#
    .SYNOPSIS
        Applies and verifies a config-defined registry combo-box state.

    .PARAMETER Registry
        Registry settings containing a value mapping for each supported state.

    .PARAMETER State
        The state name to apply.
    #>
    param(
        [Parameter(Mandatory)]
        $Registry,

        [Parameter(Mandatory)]
        [string]$State
    )

    if ($Registry[0].Values.PSObject.Properties.Name -notcontains $State) {
        throw "Unknown registry state '$State'."
    }

    # Preserve exact prior values so a partial update can be rolled back.
    $previousValues = foreach ($setting in @($Registry)) {
        $currentValue = Get-WinUtilRegistryComboValue -Setting $setting
        [pscustomobject]@{ Setting = $setting; Exists = $currentValue.Exists; Value = $currentValue.Value }
    }

    try {
        foreach ($setting in @($Registry)) {
            $configuredValue = $setting.Values.PSObject.Properties[$State].Value
            $previousValue = $previousValues | Where-Object Setting -EQ $setting
            if ($configuredValue -ne "<RemoveEntry>" -or $previousValue.Exists) {
                Set-WinUtilRegistry -Name $setting.Name -Path $setting.Path -Type $setting.Type -Value $configuredValue
            }
        }

        # Set-WinUtilRegistry reports write errors without throwing, so verify each result explicitly.
        foreach ($setting in @($Registry)) {
            $configuredValue = $setting.Values.PSObject.Properties[$State].Value
            $currentValue = Get-WinUtilRegistryComboValue -Setting $setting
            $writeMatches = if ($configuredValue -eq "<RemoveEntry>") {
                -not $currentValue.Exists
            } else {
                $currentValue.Exists -and [string]$currentValue.Value -eq [string]$configuredValue
            }
            if (-not $writeMatches) {
                throw "The registry values did not match the requested state."
            }
        }
    } catch {
        $applyError = $_.Exception.Message
        if ([string]::IsNullOrWhiteSpace($applyError)) {
            $applyError = "The registry values did not match the requested state."
        }
        $rollbackFailed = $false
        foreach ($previousValue in $previousValues) {
            try {
                $currentValue = Get-WinUtilRegistryComboValue -Setting $previousValue.Setting
                if ($previousValue.Exists -or $currentValue.Exists) {
                    $rollbackValue = if ($previousValue.Exists) { $previousValue.Value } else { "<RemoveEntry>" }
                    Set-WinUtilRegistry -Name $previousValue.Setting.Name -Path $previousValue.Setting.Path -Type $previousValue.Setting.Type -Value $rollbackValue
                }
                $restoredValue = Get-WinUtilRegistryComboValue -Setting $previousValue.Setting
                if ($restoredValue.Exists -ne $previousValue.Exists -or ($restoredValue.Exists -and [string]$restoredValue.Value -ne [string]$previousValue.Value)) {
                    $rollbackFailed = $true
                }
            } catch {
                $rollbackFailed = $true
            }
        }
        if ($rollbackFailed) {
            throw "Unable to apply registry state '$State': $applyError. The previous registry state could not be restored."
        }
        throw "Unable to apply registry state '$State': $applyError"
    }
}

Function Set-WinUtilService {
    <#

    .SYNOPSIS
        Changes the startup type of the given service

    .PARAMETER Name
        The name of the service to modify

    .PARAMETER StartupType
        The startup type to set the service to

    .EXAMPLE
        Set-WinUtilService -Name "HomeGroupListener" -StartupType "Manual"

    #>
    param (
        $Name,
        $StartupType
    )
    try {
        Write-Host "Setting Service $Name to $StartupType"
        Write-WinUtilLog -Component "Service" -Message "Setting service $Name startup type to $StartupType"

        # Check if the service exists
        $service = Get-Service -Name $Name -ErrorAction Stop

        if (($service.PSObject.Properties.Name -contains "StartType") -and ([string]$service.StartType -eq [string]$StartupType) ) {
            Write-Host "Service $Name is already set to $StartupType"
            Write-WinUtilLog -Component "Service" -Message "Service $Name startup type is already $StartupType; no change needed."
            return
        }

        # Service exists, proceed with changing properties -- while handling auto delayed start for PWSH 5
        if (($PSVersionTable.PSVersion.Major -lt 7) -and ($StartupType -eq "AutomaticDelayedStart")) {
            sc.exe config $Name start= delayed-auto
            if ($LASTEXITCODE -ne 0) {
                throw "sc.exe config failed with exit code $LASTEXITCODE"
            }
        } else {
            $service | Set-Service -StartupType $StartupType -ErrorAction Stop
        }
        Write-WinUtilLog -Component "Service" -Message "Service $Name startup type set to $StartupType"
    } catch {
        if ($_.FullyQualifiedErrorId -like "NoServiceFoundForGivenName,*") {
            Write-Warning "Service $Name was not found."
            Write-WinUtilLog -Level "WARN" -Component "Service" -Message "Service $Name was not found."
        } else {
            Write-Warning "Unable to set $Name due to unhandled exception."
            Write-Warning $_.Exception.Message
            Write-WinUtilLog -Level "ERROR" -Component "Service" -Message "Unable to set service $Name to $StartupType`: $($_.Exception.Message)"
        }
    }

}

function Set-WinUtilTaskbaritem {
    <#

    .SYNOPSIS
        Modifies the Taskbaritem of the WPF Form

    .PARAMETER value
        Value can be between 0 and 1, 0 being no progress done yet and 1 being fully completed
        Value does not affect item without setting the state to 'Normal', 'Error' or 'Paused'
        Set-WinUtilTaskbaritem -value 0.5

    .PARAMETER state
        State can be 'None' > No progress, 'Indeterminate' > inf. loading gray, 'Normal' > Gray, 'Error' > Red, 'Paused' > Yellow
        no value needed:
        - Set-WinUtilTaskbaritem -state "None"
        - Set-WinUtilTaskbaritem -state "Indeterminate"
        value needed:
        - Set-WinUtilTaskbaritem -state "Error"
        - Set-WinUtilTaskbaritem -state "Normal"
        - Set-WinUtilTaskbaritem -state "Paused"

    .PARAMETER overlay
        Overlay icon to display on the taskbar item, there are the presets 'None', 'logo' and 'checkmark' or you can specify a path/link to an image file.
        CTT logo preset:
        - Set-WinUtilTaskbaritem -overlay "logo"
        Checkmark preset:
        - Set-WinUtilTaskbaritem -overlay "checkmark"
        Warning preset:
        - Set-WinUtilTaskbaritem -overlay "warning"
        No overlay:
        - Set-WinUtilTaskbaritem -overlay "None"
        Custom icon (needs to be supported by WPF):
        - Set-WinUtilTaskbaritem -overlay "C:\path\to\icon.png"

    .PARAMETER description
        Description to display on the taskbar item preview
        Set-WinUtilTaskbaritem -description "This is a description"
    #>
    param (
        [string]$state,
        [double]$value,
        [string]$overlay,
        [string]$description
    )

    if ($value) {
        $sync["Form"].taskbarItemInfo.ProgressValue = $value
    }

    if ($state) {
        switch ($state) {
            'None' { $sync["Form"].taskbarItemInfo.ProgressState = "None" }
            'Indeterminate' { $sync["Form"].taskbarItemInfo.ProgressState = "Indeterminate" }
            'Normal' { $sync["Form"].taskbarItemInfo.ProgressState = "Normal" }
            'Error' { $sync["Form"].taskbarItemInfo.ProgressState = "Error" }
            'Paused' { $sync["Form"].taskbarItemInfo.ProgressState = "Paused" }
            default { throw "[Set-WinUtilTaskbarItem] Invalid state" }
        }
    }

    if ($overlay) {
        switch ($overlay) {
            'logo' {
                if (-not $sync["logorender"]) {
                    Initialize-WinUtilTaskbarOverlayAssets -IncludeLogo $true -IncludeStatusAssets $false
                }
                $sync["Form"].taskbarItemInfo.Overlay = $sync["logorender"]
            }
            'checkmark' {
                if (-not $sync["checkmarkrender"]) {
                    Initialize-WinUtilTaskbarOverlayAssets -IncludeLogo $false -IncludeStatusAssets $true
                }
                $sync["Form"].taskbarItemInfo.Overlay = $sync["checkmarkrender"]
            }
            'warning' {
                if (-not $sync["warningrender"]) {
                    Initialize-WinUtilTaskbarOverlayAssets -IncludeLogo $false -IncludeStatusAssets $true
                }
                $sync["Form"].taskbarItemInfo.Overlay = $sync["warningrender"]
            }
            'None' {
                $sync["Form"].taskbarItemInfo.Overlay = $null
            }
            default {
                if (Test-Path $overlay) {
                    $sync["Form"].taskbarItemInfo.Overlay = $overlay
                }
            }
        }
    }

    if ($description) {
        $sync["Form"].taskbarItemInfo.Description = $description
    }
}

function Get-WinUtilTelemetryTaskTargets {
    # Explicit allowlist: no Windows Update, Defender, maintenance or UCPD tasks.
    # Firefox creates a machine/profile-specific hex suffix, so it is the only
    # entry resolved by a strict name pattern inside its exact Mozilla folder.
    return @(
        [pscustomobject]@{ TaskPath = '\Microsoft\Windows\Application Experience\'; TaskName = 'Microsoft Compatibility Appraiser' }
        [pscustomobject]@{ TaskPath = '\Microsoft\Windows\Application Experience\'; TaskName = 'ProgramDataUpdater' }
        [pscustomobject]@{ TaskPath = '\Microsoft\Windows\Customer Experience Improvement Program\'; TaskName = 'Consolidator' }
        [pscustomobject]@{ TaskPath = '\Microsoft\Windows\Customer Experience Improvement Program\'; TaskName = 'UsbCeip' }
        [pscustomobject]@{ TaskPath = '\Microsoft\Windows\Customer Experience Improvement Program\'; TaskName = 'KernelCeipTask' }
        [pscustomobject]@{ TaskPath = '\Microsoft\Windows\Application Experience\'; TaskName = 'Microsoft Compatibility Appraiser Exp' }
        [pscustomobject]@{ TaskPath = '\Microsoft\Windows\Windows Media Sharing\'; TaskName = 'UpdateLibrary' }
        [pscustomobject]@{ TaskPath = '\Microsoft\Windows\Flighting\FeatureConfig\'; TaskName = 'UsageDataReporting' }
        [pscustomobject]@{ TaskPath = '\Microsoft\Windows\Sustainability\'; TaskName = 'SustainabilityTelemetry' }
        [pscustomobject]@{ TaskPath = '\Mozilla\'; TaskName = 'Firefox Default Browser Agent'; TaskNameRegex = '^Firefox Default Browser Agent [0-9A-Fa-f]{8,64}$' }
    )
}

function Test-WinUtilTelemetryTaskAllowed {
    param([Parameter(Mandatory)][string]$TaskPath, [Parameter(Mandatory)][string]$TaskName)
    foreach ($target in Get-WinUtilTelemetryTaskTargets) {
        if ($target.TaskPath -ne $TaskPath) { continue }
        if ($target.TaskNameRegex) {
            if ($TaskName -cmatch $target.TaskNameRegex) { return $true }
        } elseif ($TaskName -eq $target.TaskName) {
            return $true
        }
    }
    return $false
}

function Get-WinUtilTelemetryTaskBackup {
    $saved = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\OptiUtil\TelemetryTaskBackup' -Name Snapshot -ErrorAction SilentlyContinue
    if (-not $saved -or [string]::IsNullOrWhiteSpace([string]$saved.Snapshot)) { return $null }
    $backup = ConvertFrom-Json -InputObject ([string]$saved.Snapshot) -ErrorAction Stop
    if ($backup.Version -ne 1 -or @($backup.Tasks).Count -lt 1) {
        throw 'Unrecognized telemetry task backup; no changes were made.'
    }
    $seen = @{}
    foreach ($entry in @($backup.Tasks)) {
        $key = [string]$entry.TaskPath + [string]$entry.TaskName
        if (-not (Test-WinUtilTelemetryTaskAllowed -TaskPath $entry.TaskPath -TaskName $entry.TaskName) -or
            $seen.ContainsKey($key) -or
            $entry.Enabled -isnot [bool]) {
            throw 'Telemetry task backup contains an invalid or duplicate target; no changes were made.'
        }
        $seen[$key] = $true
    }
    return $backup
}

function Get-WinUtilTelemetryTask {
    param([Parameter(Mandatory)][string]$TaskPath, [Parameter(Mandatory)][string]$TaskName)
    # Query the scheduler once for exact path/name matching; do not use a wildcard
    # or assume that a task with the same short name in another folder is ours.
    return Get-ScheduledTask -ErrorAction Stop |
        Where-Object { $_.TaskPath -eq $TaskPath -and $_.TaskName -eq $TaskName } |
        Select-Object -First 1
}

function Get-WinUtilTelemetryTaskTarget {
    param([Parameter(Mandatory)][string]$Name)
    $match = @(Get-WinUtilTelemetryTaskTargets | Where-Object { $_.TaskName -eq $Name })
    if ($match.Count -ne 1) { throw "Scheduled task '$Name' is not approved for management." }
    return $match[0]
}

function Get-WinUtilTelemetryTaskMatches {
    param([Parameter(Mandatory)]$Target, [object[]]$TaskSnapshot)
    # Read the scheduler in one operation and only return entries in the
    # allowlisted folder. A UI snapshot avoids querying Windows for each row.
    $candidates = if ($PSBoundParameters.ContainsKey('TaskSnapshot')) {
        $TaskSnapshot
    } else {
        @(Get-ScheduledTask -ErrorAction Stop)
    }
    return $candidates |
        Where-Object {
            $_.TaskPath -eq $Target.TaskPath -and
            $(if ($Target.TaskNameRegex) {
                $_.TaskName -cmatch $Target.TaskNameRegex
            } else {
                $_.TaskName -eq $Target.TaskName
            })
        }
}

function Get-WinUtilTelemetryTaskInfo {
    param([Parameter(Mandatory)][string]$Name, [object[]]$TaskSnapshot, $Backup)
    $target = Get-WinUtilTelemetryTaskTarget -Name $Name
    if (-not $PSBoundParameters.ContainsKey('Backup')) {
        $Backup = Get-WinUtilTelemetryTaskBackup
    }
    $saved = @(Get-WinUtilTelemetryTaskBackupEntries -Target $target -Backup $Backup)
    [object[]]$tasks = if ($PSBoundParameters.ContainsKey('TaskSnapshot')) {
        @(Get-WinUtilTelemetryTaskMatches -Target $target -TaskSnapshot $TaskSnapshot)
    } else {
        @(Get-WinUtilTelemetryTaskMatches -Target $target)
    }
    $disabled = ($tasks.Count -gt 0 -and @($tasks | Where-Object { $_.State -ne 'Disabled' }).Count -eq 0)
    $managed = ($saved.Count -gt 0)
    $anyEnabled = @($tasks | Where-Object { $_.State -ne 'Disabled' }).Count -gt 0
    return [pscustomobject]@{
        Present = ($tasks.Count -gt 0)
        Disabled = $disabled
        Managed = $managed
        CanChange = ($tasks.Count -gt 0 -and ($anyEnabled -or $managed))
        Reason = if ($tasks.Count -eq 0) { 'Task is not installed' }
                 elseif ($disabled -and -not $managed) { 'Already disabled outside APBOptimizer: no original enabled state to restore' }
                 else { '' }
    }
}

function Get-WinUtilTelemetryTaskBackupEntries {
    param([Parameter(Mandatory)]$Target, $Backup)
    return @($Backup.Tasks | Where-Object {
        $_.TaskPath -eq $Target.TaskPath -and
        $(if ($Target.TaskNameRegex) {
            $_.TaskName -cmatch $Target.TaskNameRegex
        } else {
            $_.TaskName -eq $Target.TaskName
        })
    })
}

function Save-WinUtilTelemetryTaskBackup {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Entries)
    $backupPath = 'HKLM:\SOFTWARE\OptiUtil\TelemetryTaskBackup'
    if ($Entries.Count -eq 0) {
        Remove-ItemProperty -LiteralPath $backupPath -Name Snapshot -ErrorAction Stop
    } else {
        $null = New-Item -Path $backupPath -Force -ErrorAction Stop
        $snapshot = [pscustomobject]@{ Version = 1; Tasks = @($Entries) }
        $null = New-ItemProperty -LiteralPath $backupPath -Name Snapshot -PropertyType String -Value ($snapshot | ConvertTo-Json -Depth 5 -Compress) -Force -ErrorAction Stop
    }
}

function Get-WinUtilTelemetryTaskStatus {
    $backup = Get-WinUtilTelemetryTaskBackup
    if (-not $backup) { return $false }
    foreach ($entry in @($backup.Tasks)) {
        $task = Get-WinUtilTelemetryTask -TaskPath $entry.TaskPath -TaskName $entry.TaskName
        if (-not $task -or $task.State -ne 'Disabled') { return $false }
    }
    return $true
}

function Set-WinUtilTelemetryTask {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('Disable', 'Restore')][string]$Mode
    )
    $target = Get-WinUtilTelemetryTaskTarget -Name $Name
    if (-not (Test-WinUtilWindowsUpdateAdmin)) {
        throw 'Administrator privileges are required to manage scheduled tasks.'
    }
    foreach ($command in @('Get-ScheduledTask', 'Disable-ScheduledTask', 'Enable-ScheduledTask')) {
        if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
            throw "Task Scheduler command $command is unavailable."
        }
    }
    $backup = Get-WinUtilTelemetryTaskBackup
    [object[]]$entries = if ($backup) { @($backup.Tasks) } else { @() }
    $saved = @(Get-WinUtilTelemetryTaskBackupEntries -Target $target -Backup $backup)
    $tasks = @(Get-WinUtilTelemetryTaskMatches -Target $target)
    if ($tasks.Count -eq 0) {
        if ($saved.Count -gt 0) { throw "The backed-up task '$Name' is missing; snapshot retained." }
        Write-WinUtilLog -Component 'Tasks' -Message "Optional task '$Name' is not installed. Skipping."
        return
    }

    if ($Mode -eq 'Disable') {
        $pending = @($tasks | Where-Object {
            $taskEntry = $_
            $taskEntry.State -ne 'Disabled' -and
                @($entries | Where-Object {
                    $_.TaskPath -eq $taskEntry.TaskPath -and $_.TaskName -eq $taskEntry.TaskName
                }).Count -eq 0
        })
        if ($pending.Count -gt 0) {
            # Journal all original states before the first change, including
            # every matching Firefox agent when multiple profiles are present.
            foreach ($task in $pending) {
                $entries += [pscustomobject]@{
                    TaskPath = $task.TaskPath; TaskName = $task.TaskName; Enabled = $true
                }
            }
            Save-WinUtilTelemetryTaskBackup -Entries $entries
        }
        foreach ($task in $tasks) {
            if ($task.State -ne 'Disabled') {
                $null = Disable-ScheduledTask -TaskPath $task.TaskPath -TaskName $task.TaskName -ErrorAction Stop
            }
        }
    } else {
        if ($saved.Count -eq 0) {
            throw "No APBOptimizer backup for '$Name'; refusing to enable a task without its original state."
        }
        foreach ($entry in $saved) {
            $task = @($tasks | Where-Object { $_.TaskPath -eq $entry.TaskPath -and $_.TaskName -eq $entry.TaskName })
            if ($task.Count -ne 1) {
                throw "Backed-up scheduled task '$($entry.TaskName)' disappeared; snapshot retained."
            }
            if ($entry.Enabled -and $task[0].State -eq 'Disabled') {
                $null = Enable-ScheduledTask -TaskPath $entry.TaskPath -TaskName $entry.TaskName -ErrorAction Stop
            } elseif (-not $entry.Enabled -and $task[0].State -ne 'Disabled') {
                $null = Disable-ScheduledTask -TaskPath $entry.TaskPath -TaskName $entry.TaskName -ErrorAction Stop
            }
        }
    }

    foreach ($task in $tasks) {
        $verified = Get-WinUtilTelemetryTask -TaskPath $task.TaskPath -TaskName $task.TaskName
        $previous = @($saved | Where-Object { $_.TaskPath -eq $task.TaskPath -and $_.TaskName -eq $task.TaskName })
        $shouldEnable = ($Mode -eq 'Restore' -and $previous.Count -gt 0 -and [bool]$previous[0].Enabled)
        if (-not $verified -or (($verified.State -ne 'Disabled') -ne $shouldEnable)) {
            throw "Could not verify '$($task.TaskName)' after $Mode. Snapshot retained."
        }
    }
    if ($Mode -eq 'Restore') {
        $remaining = @($entries | Where-Object {
            $entry = $_
            @($saved | Where-Object {
                $_.TaskPath -eq $entry.TaskPath -and $_.TaskName -eq $entry.TaskName
            }).Count -eq 0
        })
        Save-WinUtilTelemetryTaskBackup -Entries $remaining
    }
    Write-WinUtilLog -Component 'Tasks' -Message "$Mode optional scheduled task '$Name' verified."
}

function Set-WinUtilTelemetryTasks {
    param([Parameter(Mandatory)][ValidateSet('Disable', 'Restore')][string]$Mode)
    # Backward-compatible entry point for older APBOptimizer exports containing
    # WPFTweaksDisableTelemetryTasks. The new group calls each task separately.
    if ($Mode -eq 'Restore') {
        $backup = Get-WinUtilTelemetryTaskBackup
        if (-not $backup) { throw 'No APBOptimizer telemetry task backup exists.' }
        $names = @(foreach ($target in Get-WinUtilTelemetryTaskTargets) {
            if (@(Get-WinUtilTelemetryTaskBackupEntries -Target $target -Backup $backup).Count -gt 0) {
                $target.TaskName
            }
        })
    } else {
        # This entry point belonged to the former five-task bulk checkbox.
        # Never disable newly added optional tasks from an old preset/export.
        $names = @(
            'Microsoft Compatibility Appraiser', 'ProgramDataUpdater',
            'Consolidator', 'UsbCeip', 'KernelCeipTask'
        )
    }
    foreach ($name in $names) {
        Set-WinUtilTelemetryTask -Name $name -Mode $Mode
    }
}

function Get-WinUtilWindowsPauseNames {
    return @(
        'PauseFeatureUpdatesStartTime',
        'PauseQualityUpdatesStartTime',
        'PauseUpdatesStartTime',
        'PauseUpdatesExpiryTime',
        'PauseFeatureUpdatesEndTime',
        'PauseQualityUpdatesEndTime'
    )
}

function Get-WinUtilWindowsPauseValues {
    $path = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
    $key = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
    $values = @()
    if ($key) {
        $names = @($key.GetValueNames())
        foreach ($name in @(Get-WinUtilWindowsPauseNames)) {
            if ($name -notin $names) { continue }
            $kind = [string]$key.GetValueKind($name)
            $value = $key.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            $values += [pscustomobject]@{ Name = $name; Kind = $kind; Value = $value }
        }
    }
    return @($values)
}

function Get-WinUtilWindowsPauseState {
    $entries = @(Get-WinUtilWindowsPauseValues)
    $expiry = $entries | Where-Object { $_.Name -eq 'PauseUpdatesExpiryTime' -and $_.Kind -eq 'String' } | Select-Object -First 1
    if ($expiry -and $expiry.Value -eq '2099-08-17T20:09:55Z') { return 'Registry2099' }
    if (@($entries | Where-Object { $_.Name -eq 'PauseUpdatesExpiryTime' }).Count -gt 0) { return 'ExistingPause' }
    return 'NoPause'
}

function Set-WinUtilWindowsPause {
    param([Parameter(Mandatory)][ValidateSet('Pause', 'Restore')][string]$Mode)

    if (-not (Test-WinUtilWindowsUpdateAdmin)) {
        throw 'Administrator privileges are required to configure Windows Update pause settings.'
    }

    $path = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
    $backupPath = 'HKLM:\SOFTWARE\OptiUtil\WindowsPauseBackup'
    $backup = Get-ItemProperty -LiteralPath $backupPath -Name Snapshot -ErrorAction SilentlyContinue
    $snapshot = $null
    if ($backup) {
        if ([string]::IsNullOrWhiteSpace($backup.Snapshot)) { throw 'Windows Update pause backup is empty.' }
        $snapshot = $backup.Snapshot | ConvertFrom-Json -ErrorAction Stop
        if ($snapshot.Version -ne 1) { throw 'Unsupported Windows Update pause backup version.' }
    }

    if ($Mode -eq 'Pause') {
        if (-not $snapshot) {
            $snapshot = [pscustomobject]@{
                Version = 1
                KeyExisted = [bool](Test-Path -LiteralPath $path)
                Values = @(Get-WinUtilWindowsPauseValues)
            }
            $null = New-Item -Path $backupPath -Force -ErrorAction Stop
            $json = $snapshot | ConvertTo-Json -Depth 7 -Compress
            $null = New-ItemProperty -LiteralPath $backupPath -Name Snapshot -Value $json -PropertyType String -Force -ErrorAction Stop
        }

        $now = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)
        $expiry = '2099-08-17T20:09:55Z'
        $startNames = @('PauseFeatureUpdatesStartTime', 'PauseQualityUpdatesStartTime', 'PauseUpdatesStartTime')
        $endNames = @('PauseUpdatesExpiryTime', 'PauseFeatureUpdatesEndTime', 'PauseQualityUpdatesEndTime')
        $null = New-Item -Path $path -Force -ErrorAction Stop
        foreach ($name in $startNames) {
            $null = New-ItemProperty -LiteralPath $path -Name $name -Value $now -PropertyType String -Force -ErrorAction Stop
        }
        foreach ($name in $endNames) {
            $null = New-ItemProperty -LiteralPath $path -Name $name -Value $expiry -PropertyType String -Force -ErrorAction Stop
        }
        $applied = @(Get-WinUtilWindowsPauseValues)
        foreach ($name in $startNames) {
            if (-not @($applied | Where-Object { $_.Name -eq $name -and $_.Kind -eq 'String' -and $_.Value -eq $now }).Count) {
                throw "Pause registry value $name did not persist; backup kept."
            }
        }
        foreach ($name in $endNames) {
            if (-not @($applied | Where-Object { $_.Name -eq $name -and $_.Kind -eq 'String' -and $_.Value -eq $expiry }).Count) {
                throw "Pause registry value $name did not persist; backup kept."
            }
        }
        Write-WinUtilLog -Component 'WindowsPause' -Message 'Wrote experimental Windows Update pause dates through 2099-08-17. Actual Windows Update enforcement is not guaranteed.'
        return
    }

    if (-not $snapshot) { throw 'No Windows Update pause backup exists; refusing to overwrite unknown registry settings.' }
    $failed = $false
    foreach ($name in @(Get-WinUtilWindowsPauseNames)) {
        try {
            $previous = $snapshot.Values | Where-Object { $_.Name -eq $name } | Select-Object -First 1
            if ($previous) {
                $value = $previous.Value
                switch ($previous.Kind) {
                    'Binary' { $value = [byte[]]@($previous.Value) }
                    'MultiString' { $value = [string[]]@($previous.Value) }
                    'DWord' { $value = [int]$previous.Value }
                    'QWord' { $value = [long]$previous.Value }
                }
                $null = New-Item -Path $path -Force -ErrorAction Stop
                $null = New-ItemProperty -LiteralPath $path -Name $name -Value $value -PropertyType $previous.Kind -Force -ErrorAction Stop
            } else {
                $key = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
                if ($key -and $name -in @($key.GetValueNames())) {
                    Remove-ItemProperty -LiteralPath $path -Name $name -ErrorAction Stop
                }
            }
        } catch {
            $failed = $true
            Write-Warning "Could not restore pause value $name`: $($_.Exception.Message)"
        }
    }

    $current = @(Get-WinUtilWindowsPauseValues)
    foreach ($name in @(Get-WinUtilWindowsPauseNames)) {
        $previous = $snapshot.Values | Where-Object { $_.Name -eq $name } | Select-Object -First 1
        $actual = $current | Where-Object { $_.Name -eq $name } | Select-Object -First 1
        if (($null -eq $previous) -ne ($null -eq $actual) -or ($previous -and $actual -and (
            $previous.Kind -ne $actual.Kind -or
            (ConvertTo-Json -InputObject $previous.Value -Compress -Depth 4) -ne (ConvertTo-Json -InputObject $actual.Value -Compress -Depth 4)
        ))) {
            $failed = $true
            Write-Warning "Pause value $name could not be verified after restoration."
        }
    }
    if ($failed) {
        Write-Warning 'Windows Update pause restoration incomplete. Saved values kept for another attempt.'
    } else {
        Remove-Item -LiteralPath $backupPath -Force -ErrorAction Stop
        Write-WinUtilLog -Component 'WindowsPause' -Message 'Original Windows Update pause registry values restored.'
    }
}

function Get-WinUtilWindowsUpdateState {
    try {
        $service = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\wuauserv' -Name Start -ErrorAction Stop
        $dlls = @(Get-WinUtilWindowsUpdateFiles)
        $renamedCount = @($dlls | Where-Object {
            -not (Test-Path -LiteralPath $_.OriginalPath) -and (Test-Path -LiteralPath $_.RenamedPath)
        }).Count
        if ($renamedCount -eq $dlls.Count -and $service.Start -eq 4) { return 'Disabled' }
        if ($renamedCount -gt 0 -or $service.Start -eq 4) { return 'Partial' }
        return 'Enabled'
    } catch { return 'Unknown' }
}

function Test-WinUtilWindowsUpdateRecoveryRequired {
    $path = 'HKLM:\SOFTWARE\OptiUtil\WindowsUpdateBackup'
    $existing = Get-ItemProperty -LiteralPath $path -Name Snapshot -ErrorAction SilentlyContinue
    $snapshot = $null
    if ($existing -and $existing.Snapshot) {
        try { $snapshot = $existing.Snapshot | ConvertFrom-Json -ErrorAction Stop }
        catch { return $false }
    }
    foreach ($file in @(Get-WinUtilWindowsUpdateFiles)) {
        if ((Test-Path -LiteralPath $file.OriginalPath) -or -not (Test-Path -LiteralPath $file.RenamedPath)) { continue }
        if ($null -eq $snapshot) { return $true }
        $entry = $snapshot.Files | Where-Object { $_.Name -eq $file.Name } | Select-Object -First 1
        if ($null -eq $entry -or -not $entry.OriginalExisted -or $entry.RenamedExisted) { return $true }
    }
    return $false
}

function Get-WinUtilWindowsUpdateRestoreIssues {
    $issues = @()
    foreach ($file in @(Get-WinUtilWindowsUpdateFiles)) {
        if (-not (Test-Path -LiteralPath $file.OriginalPath)) {
            $issues += "Missing $($file.Name).dll"
        }
        if (Test-Path -LiteralPath $file.RenamedPath) {
            $issues += "$($file.Name)_BAK.dll is still present"
        }
    }
    foreach ($name in @('wuauserv', 'UsoSvc', 'WaaSMedicSvc')) {
        $service = Get-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Services\$name" -Name Start -ErrorAction SilentlyContinue
        if ($service -and [int]$service.Start -eq 4) { $issues += "Service $name remains disabled" }
    }
    $policy = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -Name NoAutoUpdate -ErrorAction SilentlyContinue
    if ($policy -and $policy.NoAutoUpdate -eq 1) { $issues += 'NoAutoUpdate is still 1' }
    return @($issues)
}

function Update-WinUtilWindowsUpdateStatusUI {
    if ($null -eq $sync.WPFWindowsUpdateStatus) { return }
    $state = Get-WinUtilWindowsUpdateState
    $messages = if ($sync.Language -eq 'es') {
        @{ Disabled = 'Estado: DLL de Windows Update renombradas y servicio deshabilitado.'; Partial = 'Estado: bloqueo parcial. Revisa el registro.'; Enabled = 'Estado: Windows Update no está bloqueado por APBOptimizer.'; Unknown = 'Estado: no se pudo consultar.' }
    } else {
        @{ Disabled = 'Status: Windows Update DLLs renamed and service disabled.'; Partial = 'Status: partially disabled. Check the log.'; Enabled = 'Status: Windows Update is not blocked by APBOptimizer.'; Unknown = 'Status: could not query Windows Update.' }
    }
    $hasSnapshot = $null -ne (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\OptiUtil\WindowsUpdateBackup' -Name Snapshot -ErrorAction SilentlyContinue)
    $needsRecovery = Test-WinUtilWindowsUpdateRecoveryRequired
    $canRestore = $hasSnapshot -or $needsRecovery
    $statusText = $messages[$state]
    if ($needsRecovery) {
        $statusText = if ($sync.Language -eq 'es') {
            'Estado: hay DLL renombradas que requieren recuperación. Pulsa Restaurar Windows Update.'
        } else {
            'Status: renamed DLLs need recovery. Select Restore Windows Update.'
        }
    }
    Invoke-WPFUIThread -Async -Parameters @{ Text = $statusText; CanRestore = $canRestore } -ScriptBlock {
        param($Text, $CanRestore)
        if ($sync.WPFWindowsUpdateStatus) { $sync.WPFWindowsUpdateStatus.Text = $Text }
        if ($sync.WPFRestoreWindowsUpdate) { $sync.WPFRestoreWindowsUpdate.IsEnabled = [bool]$CanRestore }
    }
}

function Test-WinUtilWindowsUpdateAdmin {
    $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Save-WinUtilWindowsUpdateSnapshot {
    param([Parameter(Mandatory)]$Snapshot)
    $path = 'HKLM:\SOFTWARE\OptiUtil\WindowsUpdateBackup'
    $null = New-Item -Path $path -Force -ErrorAction Stop
    $json = $Snapshot | ConvertTo-Json -Depth 8 -Compress
    $null = New-ItemProperty -LiteralPath $path -Name Snapshot -Value $json -PropertyType String -Force -ErrorAction Stop
}

function Set-WinUtilWindowsUpdateServiceStartup {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('Automatic', 'Manual', 'Disabled')][string]$StartupType,
        [bool]$Delayed = $false
    )
    $startValue = @{ Automatic = 2; Manual = 3; Disabled = 4 }[$StartupType]
    try {
        if ($StartupType -eq 'Automatic' -and $Delayed) {
            $output = & sc.exe config $Name 'start=' 'delayed-auto' 2>&1
            if ($LASTEXITCODE -ne 0) { throw "sc.exe returned $LASTEXITCODE`: $output" }
        } else {
            Set-Service -Name $Name -StartupType $StartupType -ErrorAction Stop
        }
    } catch {
        # SCM may deny SERVICE_CHANGE_CONFIG on protected services even to an
        # elevated administrator. Match the BAT's direct Start value fallback.
        Set-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Services\$Name" -Name Start -Value $startValue -ErrorAction Stop
        if ($StartupType -eq 'Automatic') {
            Set-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Services\$Name" -Name DelayedAutoStart -Value ([int]$Delayed) -ErrorAction Stop
        }
        Write-WinUtilLog -Component 'WindowsUpdate' -Message "Service $Name startup changed via registry fallback (SCM refused direct change)."
    }
}

function Restore-WinUtilWindowsUpdateLegacyPolicy {
    param([Parameter(Mandatory)]$Snapshot)
    if ($null -eq $Snapshot.LegacyPolicy -or -not $Snapshot.LegacyPolicy.Pending) { return }
    # One-time migration: undo the NoAutoUpdate value applied by the earlier
    # APBOptimizer version. New installations never change this Windows policy.
    $path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
    if ($Snapshot.LegacyPolicy.Present) {
        $null = New-Item -Path $path -Force -ErrorAction Stop
        $null = New-ItemProperty -LiteralPath $path -Name NoAutoUpdate -PropertyType DWord -Value ([int]$Snapshot.LegacyPolicy.Value) -Force -ErrorAction Stop
    } elseif (Get-ItemProperty -LiteralPath $path -Name NoAutoUpdate -ErrorAction SilentlyContinue) {
        Remove-ItemProperty -LiteralPath $path -Name NoAutoUpdate -ErrorAction Stop
    }
    $Snapshot.LegacyPolicy.Pending = $false
    Save-WinUtilWindowsUpdateSnapshot -Snapshot $Snapshot
    Write-WinUtilLog -Component 'WindowsUpdate' -Message 'Restored legacy NoAutoUpdate policy; aggressive mode no longer uses it.'
}

function Initialize-WinUtilWindowsUpdateRecovery {
    param($Snapshot)

    if ($null -eq $Snapshot) {
        $Snapshot = [pscustomobject]@{
            Version = 2; RecoveryOnly = $true; Services = @(); Tasks = @()
            Files = @(); LegacyPolicy = $null
        }
    }
    # There is no longer an original baseline. Explicit recovery uses the ACL
    # on the renamed file and a working Manual service startup, not invented
    # "original" values. Save this repair journal before changing anything.
    foreach ($file in @(Get-WinUtilWindowsUpdateFiles)) {
        if ((Test-Path -LiteralPath $file.OriginalPath) -or -not (Test-Path -LiteralPath $file.RenamedPath)) { continue }
        $entry = @($Snapshot.Files | Where-Object { $_.Name -eq $file.Name } | Select-Object -First 1)
        if ($entry.Count -gt 0 -and $entry[0].OriginalExisted -and -not $entry[0].RenamedExisted) { continue }
        $descriptor = (Get-Acl -LiteralPath $file.RenamedPath -ErrorAction Stop).Sddl
        if ([string]::IsNullOrWhiteSpace($descriptor)) { throw "Cannot safely recover $($file.Name).dll without its current security descriptor." }
        $Snapshot.Files = @($Snapshot.Files | Where-Object { $_.Name -ne $file.Name }) + @([pscustomobject]@{
            Name = $file.Name; OriginalExisted = $true
            RenamedExisted = $false; SecurityDescriptor = $descriptor
        })
    }
    foreach ($name in @('wuauserv', 'UsoSvc', 'WaaSMedicSvc')) {
        $service = Get-Service -Name $name -ErrorAction SilentlyContinue
        $settings = Get-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Services\$name" -Name Start -ErrorAction SilentlyContinue
        if (-not $service -or -not $settings -or [int]$settings.Start -ne 4) { continue }
        $entry = @($Snapshot.Services | Where-Object { $_.Name -eq $name } | Select-Object -First 1)
        if ($entry.Count -gt 0 -and $entry[0].Changed -and [int]$entry[0].Start -ne 4) { continue }
        $Snapshot.Services = @($Snapshot.Services | Where-Object { $_.Name -ne $name }) + @([pscustomobject]@{
            Name = $name; Start = 3; Delayed = 0; Running = $false; Changed = $true
        })
    }
    $policy = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -Name NoAutoUpdate -ErrorAction SilentlyContinue
    if ($policy -and $policy.NoAutoUpdate -eq 1) {
        $Snapshot.LegacyPolicy = [pscustomobject]@{ Present = $false; Value = 0; Pending = $true }
    }
    Save-WinUtilWindowsUpdateSnapshot -Snapshot $Snapshot
    Write-WinUtilLog -Component 'WindowsUpdate' -Message 'Started explicit recovery of missing DLLs and update configuration. Original settings may be unknown.'
    return $Snapshot
}

function Set-WinUtilWindowsUpdate {
    param([Parameter(Mandatory)][ValidateSet('Disable', 'Restore', 'Recover')][string]$Mode)

    if (-not (Test-WinUtilWindowsUpdateAdmin)) {
        throw 'Administrator privileges are required to change Windows Update.'
    }

    $backupPath = 'HKLM:\SOFTWARE\OptiUtil\WindowsUpdateBackup'
    $original = $null
    if (Test-Path -LiteralPath $backupPath) {
        $saved = (Get-ItemProperty -LiteralPath $backupPath -Name Snapshot -ErrorAction Stop).Snapshot
        if ([string]::IsNullOrWhiteSpace($saved)) { throw 'Windows Update backup is empty.' }
        $original = $saved | ConvertFrom-Json -ErrorAction Stop
        if ($original.Version -notin @(1, 2)) { throw 'Windows Update backup has an unsupported version.' }
    }

    if ($null -ne $original -and $original.Version -eq 1) {
        # Preserve the original V1 baseline, even when Windows Update has already
        # been partially disabled. Only restore settings this tool actually changed.
        foreach ($entry in @($original.Services)) {
            $current = Get-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Services\$($entry.Name)" -ErrorAction Stop
            $entry | Add-Member -NotePropertyName Changed -NotePropertyValue ([int]$current.Start -ne [int]$entry.Start) -Force
        }
        if (-not @($original.Services | Where-Object { $_.Name -eq 'uhssvc' }).Count) {
            $health = Get-Service -Name 'uhssvc' -ErrorAction SilentlyContinue
            if ($health) {
                $healthSettings = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\uhssvc' -ErrorAction Stop
                $original.Services = @($original.Services) + @([pscustomobject]@{
                    Name = 'uhssvc'; Start = [int]$healthSettings.Start
                    Delayed = [int]$healthSettings.DelayedAutoStart
                    Running = ($health.Status -eq 'Running'); Changed = $false
                })
            }
        }
        # Old snapshots can contain scheduled-task metadata. Preserve it as
        # historical data, but never inspect or change Task Scheduler entries.
        $original | Add-Member -NotePropertyName LegacyPolicy -NotePropertyValue ([pscustomobject]@{
            Present = [bool]$original.PolicyPresent
            Value = [int]$original.PolicyValue
            Pending = $true
        }) -Force
        $original | Add-Member -NotePropertyName Files -NotePropertyValue @(Get-WinUtilWindowsUpdateFileSnapshot) -Force
        $original.Version = 2
        Save-WinUtilWindowsUpdateSnapshot -Snapshot $original
        Write-WinUtilLog -Component 'WindowsUpdate' -Message 'Migrated original Windows Update settings from backup v1 to v2.'
    }

    if ($Mode -eq 'Recover') {
        $original = Initialize-WinUtilWindowsUpdateRecovery -Snapshot $original
        $Mode = 'Restore'
    }

    if ($Mode -eq 'Disable') {
        if ($null -eq $original) {
            $services = @()
            foreach ($name in @('wuauserv', 'UsoSvc', 'uhssvc', 'WaaSMedicSvc')) {
                $service = Get-Service -Name $name -ErrorAction SilentlyContinue
                if ($null -eq $service) { continue }
                $settings = Get-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Services\$name" -ErrorAction Stop
                $services += [pscustomobject]@{
                    Name = $name
                    Start = [int]$settings.Start
                    Delayed = [int]$settings.DelayedAutoStart
                    Running = ($service.Status -eq 'Running')
                    Changed = $false
                }
            }
            $original = [pscustomobject]@{
                Version = 2
                Services = @($services)
                Tasks = @() # Backward-compatible snapshot field; not managed.
                Files = @(Get-WinUtilWindowsUpdateFileSnapshot)
                LegacyPolicy = $null
            }
            # Save before changing Windows, and keep this snapshot for subsequent attempts.
            Save-WinUtilWindowsUpdateSnapshot -Snapshot $original
        }

        try { Restore-WinUtilWindowsUpdateLegacyPolicy -Snapshot $original }
        catch { Write-Warning "Could not remove legacy Windows Update policy: $($_.Exception.Message)" }

        foreach ($entry in $original.Services) {
            try {
                $current = Get-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Services\$($entry.Name)" -ErrorAction Stop
                if ([int]$current.Start -ne 4) {
                    Set-WinUtilWindowsUpdateServiceStartup -Name $entry.Name -StartupType Disabled
                    $entry.Changed = $true
                    Save-WinUtilWindowsUpdateSnapshot -Snapshot $original
                }
                $service = Get-Service -Name $entry.Name -ErrorAction Stop
                if ($service.Status -ne 'Stopped') {
                    Stop-Service -Name $entry.Name -Force -ErrorAction Stop
                    $entry.Changed = $true
                    Save-WinUtilWindowsUpdateSnapshot -Snapshot $original
                }
                Write-WinUtilLog -Component 'WindowsUpdate' -Message "Disabled service $($entry.Name)."
            } catch {
                Write-Warning "Could not disable Windows Update service $($entry.Name): $($_.Exception.Message)"
            }
        }
        Rename-WinUtilWindowsUpdateFiles -Snapshot $original
        Write-WinUtilLog -Component 'WindowsUpdate' -Message 'Disable attempt completed. Previous settings retained for restoration.'
        return
    }

    if ($null -eq $original) {
        throw 'No APBOptimizer Windows Update backup exists. Cannot safely restore unknown settings.'
    }

    $failed = $false
    if (-not (Restore-WinUtilWindowsUpdateFiles -Snapshot $original)) { $failed = $true }
    foreach ($entry in $original.Services | Where-Object { $_.Changed }) {
        try {
            $startupMode = switch ([int]$entry.Start) {
                2 { 'Automatic' }
                3 { 'Manual' }
                4 { 'Disabled' }
                default { throw "Unexpected original startup mode for $($entry.Name): $($entry.Start)" }
            }
            Set-WinUtilWindowsUpdateServiceStartup -Name $entry.Name -StartupType $startupMode -Delayed ([int]$entry.Delayed -eq 1)
            if ($entry.Running -and $startupMode -ne 'Disabled') {
                $service = Get-Service -Name $entry.Name -ErrorAction Stop
                if ($service.Status -ne 'Running') { Start-Service -Name $entry.Name -ErrorAction Stop }
            }
            $entry.Changed = $false
            Save-WinUtilWindowsUpdateSnapshot -Snapshot $original
        } catch {
            $failed = $true
            Write-Warning "Could not restore service $($entry.Name): $($_.Exception.Message)"
        }
    }

    try { Restore-WinUtilWindowsUpdateLegacyPolicy -Snapshot $original }
    catch {
        $failed = $true
        Write-Warning "Could not restore old APBOptimizer NoAutoUpdate policy: $($_.Exception.Message)"
    }

    $remaining = @(Get-WinUtilWindowsUpdateRestoreIssues)
    if ($remaining.Count -gt 0) {
        $failed = $true
        foreach ($issue in $remaining) { Write-Warning "Windows Update restoration incomplete: $issue" }
    }
    if ($failed) {
        Write-Warning 'Some settings could not be restored. The backup was kept so you can retry.'
    } else {
        Remove-Item -LiteralPath $backupPath -Force -ErrorAction Stop
        Write-WinUtilLog -Component 'WindowsUpdate' -Message 'Original Windows Update settings restored.'
    }
}

function Show-CustomDialog {
    <#
    .SYNOPSIS
    Displays a custom dialog box with an image, heading, message, and an OK button.

    .DESCRIPTION
    This function creates a custom dialog box with the specified message and additional elements such as an image, heading, and an OK button. The dialog box is designed with a green border, rounded corners, and a black background.

    .PARAMETER Title
    The Title to use for the dialog window's Title Bar, this will not be visible by the user, as window styling is set to None.

    .PARAMETER Message
    The message to be displayed in the dialog box.

    .PARAMETER Width
    The width of the custom dialog window.

    .PARAMETER Height
    The height of the custom dialog window.

    .PARAMETER FontSize
    The Font Size of message shown inside custom dialog window.

    .PARAMETER HeaderFontSize
    The Font Size for the Header of custom dialog window.

    .PARAMETER LogoSize
    The Size of the Logo used inside the custom dialog window.

    .PARAMETER ForegroundColor
    The Foreground Color of dialog window title & message.

    .PARAMETER BackgroundColor
    The Background Color of dialog window.

    .PARAMETER BorderColor
    The Color for dialog window border.

    .PARAMETER ButtonBackgroundColor
    The Background Color for Buttons in dialog window.

    .PARAMETER ButtonForegroundColor
    The Foreground Color for Buttons in dialog window.

    .PARAMETER ShadowColor
    The Color used when creating the Drop-down Shadow effect for dialog window.

    .PARAMETER LogoColor
    The Color of WinUtil Text found next to WinUtil's Logo inside dialog window.

    .PARAMETER LinkForegroundColor
    The Foreground Color for Links inside dialog window.

    .PARAMETER LinkHoverForegroundColor
    The Foreground Color for Links when the mouse pointer hovers over them inside dialog window.

    .PARAMETER EnableScroll
    A flag indicating whether to enable scrolling if the content exceeds the window size.

    .EXAMPLE
    Show-CustomDialog -Title "My Custom Dialog" -Message "This is a custom dialog with a message and an image above." -Width 300 -Height 200

    Makes a new Custom Dialog with the title 'My Custom Dialog' and a message 'This is a custom dialog with a message and an image above.', with dimensions of 300 by 200 pixels.
    Other styling options are grabbed from '$sync.Form.Resources' global variable.

    .EXAMPLE
    $foregroundColor = New-Object System.Windows.Media.SolidColorBrush("#0088e5")
    $backgroundColor = New-Object System.Windows.Media.SolidColorBrush("#1e1e1e")
    $linkForegroundColor = New-Object System.Windows.Media.SolidColorBrush("#0088e5")
    $linkHoverForegroundColor = New-Object System.Windows.Media.SolidColorBrush("#005289")
    Show-CustomDialog -Title "My Custom Dialog" -Message "This is a custom dialog with a message and an image above." -Width 300 -Height 200 -ForegroundColor $foregroundColor -BackgroundColor $backgroundColor -LinkForegroundColor $linkForegroundColor -LinkHoverForegroundColor $linkHoverForegroundColor

    Makes a new Custom Dialog with the title 'My Custom Dialog' and a message 'This is a custom dialog with a message and an image above.', with dimensions of 300 by 200 pixels, with a link foreground (and general foreground) colors of '#0088e5', background color of '#1e1e1e', and Link Color on Hover of '005289', all of which are in Hexadecimal (the '#' Symbol is required by SolidColorBrush Constructor).
    Other styling options are grabbed from '$sync.Form.Resources' global variable.

    #>
    param(
        [string]$Title,
        [string]$Message,
        [string]$HeaderText = 'APBOptimizer',
        [int]$Width = $sync.Form.Resources.CustomDialogWidth,
        [int]$Height = $sync.Form.Resources.CustomDialogHeight,

        [System.Windows.Media.FontFamily]$FontFamily = $sync.Form.Resources.FontFamily,
        [int]$FontSize = $sync.Form.Resources.CustomDialogFontSize,
        [int]$HeaderFontSize = $sync.Form.Resources.CustomDialogFontSizeHeader,
        [int]$LogoSize = $sync.Form.Resources.CustomDialogLogoSize,

        [System.Windows.Media.Color]$ShadowColor = "#AAAAAAAA",
        [System.Windows.Media.SolidColorBrush]$LogoColor = $sync.Form.Resources.LabelboxForegroundColor,
        [System.Windows.Media.SolidColorBrush]$BorderColor = $sync.Form.Resources.BorderColor,
        [System.Windows.Media.SolidColorBrush]$ForegroundColor = $sync.Form.Resources.MainForegroundColor,
        [System.Windows.Media.SolidColorBrush]$BackgroundColor = $sync.Form.Resources.MainBackgroundColor,
        [System.Windows.Media.SolidColorBrush]$ButtonForegroundColor = $sync.Form.Resources.ButtonInstallForegroundColor,
        [System.Windows.Media.SolidColorBrush]$ButtonBackgroundColor = $sync.Form.Resources.ButtonInstallBackgroundColor,
        [System.Windows.Media.SolidColorBrush]$LinkForegroundColor = $sync.Form.Resources.LinkForegroundColor,
        [System.Windows.Media.SolidColorBrush]$LinkHoverForegroundColor = $sync.Form.Resources.LinkHoverForegroundColor,

        [bool]$EnableScroll = $false
    )

    # Create a custom dialog window
    $dialog = New-Object Windows.Window
    $dialog.Title = $Title
    $dialog.Height = $Height
    $dialog.Width = $Width
    $dialog.Margin = New-Object Windows.Thickness(10)  # Add margin to the entire dialog box
    $dialog.WindowStyle = [Windows.WindowStyle]::None  # Remove title bar and window controls
    $dialog.ResizeMode = [Windows.ResizeMode]::NoResize  # Disable resizing
    $dialog.WindowStartupLocation = [Windows.WindowStartupLocation]::CenterScreen  # Center the window
    $dialog.Foreground = $ForegroundColor
    $dialog.Background = $BackgroundColor
    $dialog.FontFamily = $FontFamily
    $dialog.FontSize = $FontSize

    # Create a Border for the green edge with rounded corners
    $border = New-Object Windows.Controls.Border
    $border.BorderBrush = $BorderColor
    $border.BorderThickness = New-Object Windows.Thickness(1)  # Adjust border thickness as needed
    $border.CornerRadius = New-Object Windows.CornerRadius(10)  # Adjust the radius for rounded corners

    # Create a drop shadow effect
    $dropShadow = New-Object Windows.Media.Effects.DropShadowEffect
    $dropShadow.Color = $shadowColor
    $dropShadow.Direction = 270
    $dropShadow.ShadowDepth = 5
    $dropShadow.BlurRadius = 10

    # Apply drop shadow effect to the border
    $dialog.Effect = $dropShadow

    $dialog.Content = $border

    # Create a grid for layout inside the Border
    $grid = New-Object Windows.Controls.Grid
    $border.Child = $grid

    # Uncomment the following line to show gridlines
    #$grid.ShowGridLines = $true

    # Add the following line to set the background color of the grid
    $grid.Background = [Windows.Media.Brushes]::Transparent
    # Add the following line to make the Grid stretch
    $grid.HorizontalAlignment = [Windows.HorizontalAlignment]::Stretch
    $grid.VerticalAlignment = [Windows.VerticalAlignment]::Stretch

    # Add the following line to make the Border stretch
    $border.HorizontalAlignment = [Windows.HorizontalAlignment]::Stretch
    $border.VerticalAlignment = [Windows.VerticalAlignment]::Stretch

    # Set up Row Definitions
    $row0 = New-Object Windows.Controls.RowDefinition
    $row0.Height = [Windows.GridLength]::Auto

    $row1 = New-Object Windows.Controls.RowDefinition
    $row1.Height = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star)

    $row2 = New-Object Windows.Controls.RowDefinition
    $row2.Height = [Windows.GridLength]::Auto

    # Add Row Definitions to Grid
    $grid.RowDefinitions.Add($row0)
    $grid.RowDefinitions.Add($row1)
    $grid.RowDefinitions.Add($row2)

    # Add StackPanel for horizontal layout with margins
    $stackPanel = New-Object Windows.Controls.StackPanel
    $stackPanel.Margin = New-Object Windows.Thickness(10)  # Add margins around the stack panel
    $stackPanel.Orientation = [Windows.Controls.Orientation]::Horizontal
    $stackPanel.HorizontalAlignment = [Windows.HorizontalAlignment]::Left  # Align to the left
    $stackPanel.VerticalAlignment = [Windows.VerticalAlignment]::Top  # Align to the top

    $grid.Children.Add($stackPanel)
    [Windows.Controls.Grid]::SetRow($stackPanel, 0)  # Set the row to the second row (0-based index)

    # Add SVG path to the stack panel
    $stackPanel.Children.Add((Invoke-WinUtilAssets -Type "logo" -Size $LogoSize))

    # Add "Winutil" text
    $winutilTextBlock = New-Object Windows.Controls.TextBlock
    $winutilTextBlock.Text = $HeaderText
    $winutilTextBlock.FontSize = $HeaderFontSize
    $winutilTextBlock.Foreground = $LogoColor
    $winutilTextBlock.Margin = New-Object Windows.Thickness(10, 10, 10, 5)  # Add margins around the text block
    $stackPanel.Children.Add($winutilTextBlock)
    # Add TextBlock for information with text wrapping and margins
    $messageTextBlock = New-Object Windows.Controls.TextBlock
    $messageTextBlock.FontSize = $FontSize
    $messageTextBlock.TextWrapping = [Windows.TextWrapping]::Wrap  # Enable text wrapping
    $messageTextBlock.HorizontalAlignment = [Windows.HorizontalAlignment]::Left
    $messageTextBlock.VerticalAlignment = [Windows.VerticalAlignment]::Top
    $messageTextBlock.Margin = New-Object Windows.Thickness(10)  # Add margins around the text block

    # Define the Regex to find hyperlinks formatted as HTML <a> tags
    $regex = [regex]::new('<a href="([^"]+)">([^<]+)</a>')
    $lastPos = 0
    $linkHoverBrush = $LinkHoverForegroundColor

    # Iterate through each match and add regular text and hyperlinks
    foreach ($match in $regex.Matches($Message)) {
        # Add the text before the hyperlink, if any
        $textBefore = $Message.Substring($lastPos, $match.Index - $lastPos)
        if ($textBefore.Length -gt 0) {
            $messageTextBlock.Inlines.Add((New-Object Windows.Documents.Run($textBefore)))
        }

        # Create and add the hyperlink
        $hyperlink = New-Object Windows.Documents.Hyperlink
        $hyperlink.NavigateUri = New-Object System.Uri($match.Groups[1].Value)
        $hyperlink.Inlines.Add($match.Groups[2].Value)
        $hyperlink.TextDecorations = [Windows.TextDecorations]::None  # Remove underline
        $hyperlink.Foreground = $LinkForegroundColor

        $hyperlink.Add_Click({
            param($eventSender, $routedEvent)
            $null = $routedEvent
            Start-Process $eventSender.NavigateUri.AbsoluteUri
        })
        $hyperlink.Add_MouseEnter({
            param($eventSender, $routedEvent)
            $null = $routedEvent
            $eventSender.Foreground = $linkHoverBrush
            $eventSender.FontSize = ($FontSize + ($FontSize / 4))
            $eventSender.FontWeight = "SemiBold"
        })
        $hyperlink.Add_MouseLeave({
            param($eventSender, $routedEvent)
            $null = $routedEvent
            $eventSender.Foreground = $LinkForegroundColor
            $eventSender.FontSize = $FontSize
            $eventSender.FontWeight = "Normal"
        })

        $messageTextBlock.Inlines.Add($hyperlink)

        # Update the last position
        $lastPos = $match.Index + $match.Length
    }

    # Add any remaining text after the last hyperlink
    if ($lastPos -lt $Message.Length) {
        $textAfter = $Message.Substring($lastPos)
        $messageTextBlock.Inlines.Add((New-Object Windows.Documents.Run($textAfter)))
    }

    # If no matches, add the entire message as a run
    if ($regex.Matches($Message).Count -eq 0) {
        $messageTextBlock.Inlines.Add((New-Object Windows.Documents.Run($Message)))
    }

    # Create a ScrollViewer if EnableScroll is true
    if ($EnableScroll) {
        # ScrollViewer measures its child with unconstrained width. Constrain the
        # message so long lines wrap within the dialog rather than being clipped.
        $messageTextBlock.MaxWidth = [Math]::Max(200, $Width - 65)
        $scrollViewer = New-Object System.Windows.Controls.ScrollViewer
        $scrollViewer.VerticalScrollBarVisibility = 'Auto'
        $scrollViewer.HorizontalScrollBarVisibility = 'Disabled'
        $scrollViewer.Content = $messageTextBlock
        $grid.Children.Add($scrollViewer)
        [Windows.Controls.Grid]::SetRow($scrollViewer, 1)  # Set the row to the second row (0-based index)
    } else {
        $grid.Children.Add($messageTextBlock)
        [Windows.Controls.Grid]::SetRow($messageTextBlock, 1)  # Set the row to the second row (0-based index)
    }

    # Add OK button
    $okButton = New-Object Windows.Controls.Button
    $okButton.Content = "OK"
    $okButton.FontSize = $FontSize
    $okButton.Width = 80
    $okButton.Height = 30
    $okButton.HorizontalAlignment = [Windows.HorizontalAlignment]::Center
    $okButton.VerticalAlignment = [Windows.VerticalAlignment]::Bottom
    $okButton.Margin = New-Object Windows.Thickness(0, 0, 0, 10)
    $okButton.Background = $buttonBackgroundColor
    $okButton.Foreground = $buttonForegroundColor
    $okButton.BorderBrush = $BorderColor
    $okButton.Add_Click({
        $dialog.Close()
    })
    $grid.Children.Add($okButton)
    [Windows.Controls.Grid]::SetRow($okButton, 2)  # Set the row to the third row (0-based index)

    # Handle Escape key press to close the dialog
    $dialog.Add_KeyDown({
        if ($_.Key -eq 'Escape') {
            $dialog.Close()
        }
    })

    # Set the OK button as the default button (activated on Enter)
    $okButton.IsDefault = $true

    # Show the custom dialog
    $dialog.ShowDialog()
}

function Show-WinUtilMessage {
    <#
    .SYNOPSIS
        Shows a WinUtil message box and returns the selected result.

    .DESCRIPTION
        Message boxes need the interface thread, so this marshals onto it and can therefore be
        called from a job body as well as from an event handler. Every prompt is also written to
        the session log so the log shows what the user was asked and not just what happened next.

        With no window there is nobody to click, so nothing is shown. A modal put up in that
        state never returns and takes the worker with it.
    #>
    param (
        [string]$Message,
        [string]$Title = "Winutil",
        $Button = "OK",
        $Icon = "Information"
    )

    Write-WinUtilLog -Component "Dialog" -Message "$Title : $($Message -replace '\r?\n', ' ')"

    if (-not (Test-WinUtilUIAlive)) {
        # Anything with a choice is answered with the one that does not go ahead, so a prompt
        # nobody saw can never stand in for consent
        $unattended = if ("$Button" -eq "OK") { "OK" } else { "No" }
        Write-WinUtilLog -Level "WARN" -Component "Dialog" -Message "No window to ask on, answering '$unattended' for: $Title"
        return $unattended
    }

    return Invoke-WPFUIThread -PassThru -Parameters @{
        Message = $Message
        Title = $Title
        Button = $Button
        Icon = $Icon
    } -ScriptBlock {
        param($Message, $Title, $Button, $Icon)

        [System.Windows.MessageBox]::Show($Message, $Title, $Button, $Icon)
    }
}

function Get-WinUtilTweakHelpContent {
    param([Parameter(Mandatory)][string]$Key)

    $entryProperty = $sync.configs.tweaks.PSObject.Properties[$Key]
    if (-not $entryProperty) { throw "Unknown APBOptimizer tweak: $Key" }
    $entry = $entryProperty.Value
    $spanish = $sync.Language -eq 'es'
    $translation = if ($spanish -and $sync.configs.es) {
        $sync.configs.es.PSObject.Properties[$Key]
    } else { $null }
    $translated = if ($translation) { $translation.Value } else { $null }
    $title = if ($translated -and $translated.Content) { [string]$translated.Content } else { [string]$entry.Content }
    $summary = if ($translated -and $translated.Description) { [string]$translated.Description } else { [string]$entry.Description }
    if ([string]::IsNullOrWhiteSpace($summary)) {
        $summary = if ($spanish) { 'Este ajuste modifica la configuración de Windows.' } else { 'This tweak changes Windows settings.' }
    }

    $changes = [Collections.Generic.List[string]]::new()
    $undo = [Collections.Generic.List[string]]::new()
    if ($entry.ComboItems) {
        $choices = if ([string]$entry.ComboItems -match '\|') {
            @([string]$entry.ComboItems -split '\|')
        } else {
            @([string]$entry.ComboItems -split '\s+')
        }
        $changes.Add($(if ($spanish) { 'Opciones disponibles:' } else { 'Available options:' }))
        foreach ($choice in $choices) {
            if ($choice) { $changes.Add("  $choice") }
        }
    }
    if ($entry.registry) {
        $changes.Add($(if ($spanish) { 'Registro de Windows:' } else { 'Windows Registry:' }))
        $undo.Add($(if ($spanish) { 'Restauración del Registro:' } else { 'Registry restoration:' }))
        foreach ($r in @($entry.registry)) {
            $location = "$($r.Path)\$($r.Name)"
            if ($r.Values) {
                $changes.Add("  $location")
                foreach ($state in $r.Values.PSObject.Properties) {
                    $changes.Add("    $($state.Name): $($state.Value)")
                }
                $undo.Add("  $location")
            } else {
                $changes.Add("  $location = $($r.Value)")
                $original = if ($r.OriginalValue -eq '<RemoveEntry>') {
                    if ($spanish) { 'eliminar valor' } else { 'remove value' }
                } elseif ($null -ne $r.OriginalValue) { [string]$r.OriginalValue }
                else { if ($spanish) { 'sin valor anterior definido' } else { 'no previous value defined' } }
                $undo.Add("  $location = $original")
            }
        }
    }
    if ($entry.service) {
        $changes.Add($(if ($spanish) { 'Servicios:' } else { 'Services:' }))
        $undo.Add($(if ($spanish) { 'Inicio de servicios:' } else { 'Service startup:' }))
        foreach ($svc in @($entry.service)) {
            $changes.Add("  $($svc.Name): $($svc.StartupType)")
            if ($svc.OriginalType) { $undo.Add("  $($svc.Name): $($svc.OriginalType)") }
        }
    }
    if ($entry.InvokeScript) {
        $changes.Add($(if ($spanish) { 'Comandos adicionales (fragmento):' } else { 'Additional commands (excerpt):' }))
        $commands = @($entry.InvokeScript | ForEach-Object {
            $_ -split '\r?\n' | Where-Object { $_.Trim() -and $_.Trim() -notmatch '^#' }
        })
        foreach ($command in @($commands | Select-Object -First 5)) {
            $line = $command.Trim()
            if ($line.Length -gt 115) { $line = $line.Substring(0, 112) + '...' }
            $changes.Add("  $line")
        }
        if ($commands.Count -gt 5) {
            $changes.Add($(if ($spanish) { "  (+$($commands.Count - 5) líneas)" } else { "  (+$($commands.Count - 5) lines)" }))
        }
    }
    if ($entry.UndoScript) {
        $undo.Add($(if ($spanish) { 'También ejecuta los comandos de reversión definidos por el ajuste.' } else { 'Also runs the reversal commands defined by this tweak.' }))
    }
    if (-not $changes.Count) {
        $changes.Add($(if ($spanish) { 'Ejecuta las acciones configuradas para este ajuste.' } else { 'Runs the actions configured for this tweak.' }))
    }
    if (-not $undo.Count) {
        $undo.Add($(if ($spanish) {
            'Este ajuste no define una restauración automática completa. Revisa los cambios antes de aplicarlo.'
        } else {
            'This tweak does not define a complete automatic reversal. Review its changes before applying.'
        }))
    } elseif ($entry.InvokeScript -and -not $entry.UndoScript) {
        $undo.Add($(if ($spanish) { 'Atención: algunos comandos adicionales podrían no revertirse.' } else { 'Note: some additional commands may not be reversed.' }))
    }

    return [pscustomobject]@{
        Key = $Key
        Title = $title
        Summary = $summary
        Changes = ($changes -join "`n")
        Undo = ($undo -join "`n")
        Documentation = [string]$entry.link
        Spanish = $spanish
    }
}

function Show-WinUtilTweakHelp {
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][System.Windows.UIElement]$Anchor
    )

    $data = Get-WinUtilTweakHelpContent -Key $Key
    $sync.WPFTweakHelpPopup.IsOpen = $false
    $sync.WPFTweakHelpTitle.Text = $data.Title
    $sync.WPFTweakHelpSummary.Text = $data.Summary
    $sync.WPFTweakHelpChanges.Text = $data.Changes
    $sync.WPFTweakHelpUndo.Text = $data.Undo
    $sync.WPFTweakHelpSummaryHeader.Text = if ($data.Spanish) { 'Qué hace' } else { 'What it does' }
    $sync.WPFTweakHelpChangesHeader.Text = if ($data.Spanish) { 'Cómo funciona' } else { 'How it works' }
    $sync.WPFTweakHelpUndoHeader.Text = if ($data.Spanish) { 'Cómo se revierte' } else { 'How to undo it' }
    $sync.WPFTweakHelpClose.ToolTip = if ($data.Spanish) { 'Cerrar' } else { 'Close' }
    $sync.WPFTweakHelpDocs.Content = if ($data.Spanish) { 'Ver documentación original' } else { 'Original documentation' }
    $sync.WPFTweakHelpDocs.Tag = $data.Documentation
    $sync.WPFTweakHelpDocs.Visibility = if ([string]::IsNullOrWhiteSpace($data.Documentation)) { 'Collapsed' } else { 'Visible' }
    # Anchor to the full client area, not to the tiny (?) control. WPF's
    # PlacementMode.Center now positions the enlarged help card over APBOptimizer.
    $sync.WPFTweakHelpPopup.PlacementTarget = $sync.WPFMainGrid
    $sync.WPFTweakHelpPopup.IsOpen = $true
}

function Start-WinUtilAssetRendering {
    <#
        .SYNOPSIS
            Renders the taskbar overlay bitmaps on a thread of their own

        .DESCRIPTION
            Rasterising the overlays costs the interface thread time it could spend getting the
            window up. The bitmaps are frozen before publication, so they can be built anywhere.

            Nothing waits on this: if the render has not finished when an overlay is asked for,
            Set-WinUtilTaskbaritem renders it in place.

            Needs STA for RenderTargetBitmap, which the shared worker pool is not.
    #>

    $runspace = [runspacefactory]::CreateRunspace((New-WinUtilSessionState))
    $runspace.ApartmentState = "STA"
    $runspace.ThreadOptions = "ReuseThread"
    $runspace.Open()

    $shell = [powershell]::Create()
    $shell.Runspace = $runspace
    [void]$shell.AddScript({
        # A new runspace does not inherit assemblies loaded by the interface runspace. On a cold
        # process these types otherwise fail before the off-thread render can do any work.
        Add-Type -AssemblyName WindowsBase
        Add-Type -AssemblyName PresentationCore
        Add-Type -AssemblyName PresentationFramework

        Measure-WinUtilStep -Scope "UI" -Name "render taskbar overlays (off thread)" -ScriptBlock {
            Initialize-WinUtilTaskbarOverlayAssets -IncludeLogo $true -IncludeStatusAssets $true
        }
    })

    $handle = $shell.BeginInvoke()

    Register-WinUtilRunspaceCleanup -PowerShell $shell -Handle $handle -Runspace $runspace

    return $handle
}

function Start-WinUtilBackgroundQueue {
    <#
        .SYNOPSIS
            Drains a queue of interface work one item at a time, between the things the user does

        .DESCRIPTION
            For work that must run on the interface thread but that nobody waits on: unopened
            tabs, app list entries. One item per queued operation, so input is answered between
            them instead of after the whole list.

            Re-posted rather than looped: only returning to the dispatcher lets it service input.
            Posted as a compiled action rather than through Invoke-WPFUIThread, whose body
            crosses runspaces as text and would recompile on each of the hundreds of posts a full
            app list costs.

        .PARAMETER Name
            Identifies the queue in $sync so a re-posted pump finds its state.

        .PARAMETER Queue
            The queue to drain. Items mean whatever Step says they mean.

        .PARAMETER Step
            Runs one item. Receives the dequeued item.

        .PARAMETER OnComplete
            Runs once on the interface thread after the last item.

        .PARAMETER RequiresTab
            Work drawing into this tab waits while another tab is shown.

        .PARAMETER DeferWhile
            Extra reason to hold off, tested each round. Lets a more urgent queue go first.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        $Queue,

        [Parameter(Mandatory)]
        [scriptblock]$Step,

        [scriptblock]$OnComplete,

        [string]$RequiresTab,

        [scriptblock]$DeferWhile
    )

    if ($null -eq $sync.BackgroundQueues) {
        $sync.BackgroundQueues = [hashtable]::Synchronized(@{})
    }

    $sync.BackgroundQueues[$Name] = @{
        Queue = $Queue
        Step = $Step
        OnComplete = $OnComplete
        RequiresTab = $RequiresTab
        DeferWhile = $DeferWhile
    }

    # No window means no dispatcher to spread over and nothing competing for the thread
    if (-not (Test-WinUtilUIAlive)) {
        while ($Queue.Count -gt 0) {
            # One failing item must not abandon the rest or strand the state, matching the
            # dispatcher path
            try {
                & $Step $Queue.Dequeue()
            } catch {
                Write-WinUtilErrorRecord -ErrorRecord $_ -Component "UI" -Context "Background queue '$Name'"
            }
        }
        if ($OnComplete) { & $OnComplete }
        $sync.BackgroundQueues.Remove($Name)
        return
    }

    Request-WinUtilBackgroundQueueStep -Name $Name
}

function Request-WinUtilBackgroundQueueStep {
    <#
        .SYNOPSIS
            Posts the next step of a queue at background priority

        .PARAMETER Name
            Which queue to advance.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    if (-not (Test-WinUtilUIAlive)) {
        return
    }

    # The name travels as the dispatcher's argument, not captured: this function has returned by
    # the time the block runs, and a closure would bind command lookup to a copied scope.
    $null = $sync.Form.Dispatcher.BeginInvoke(
        [System.Windows.Threading.DispatcherPriority]::Background,
        [System.Windows.Threading.DispatcherOperationCallback]{
            param($QueueName)
            Invoke-WinUtilBackgroundQueueStep -Name $QueueName
            return $null
        },
        $Name)
}

function Invoke-WinUtilBackgroundQueueStep {
    <#
        .SYNOPSIS
            Runs one item of a queue and asks for the next, or finishes

        .PARAMETER Name
            Which queue to advance.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    $state = $sync.BackgroundQueues[$Name]
    if ($null -eq $state) {
        return
    }

    if ($state.Queue.Count -gt 0) {
        $defer = (Test-WinUtilDeferBackgroundWork -RequiresTab $state.RequiresTab) -or
                 ($state.DeferWhile -and (& $state.DeferWhile))

            # Waits rather than competing with whatever the user is doing
        if ($defer) {
            Invoke-WinUtilWhenIdle -Argument $Name -Callback {
                param($QueueName)
                Invoke-WinUtilBackgroundQueueStep -Name $QueueName
            }
            return
        }

        try {
            & $state.Step $state.Queue.Dequeue()
        } catch {
            Write-WinUtilErrorRecord -ErrorRecord $_ -Component "UI" -Context "Background queue '$Name'"
        }
    }

    if ($state.Queue.Count -gt 0) {
        Request-WinUtilBackgroundQueueStep -Name $Name
        return
    }

    $sync.BackgroundQueues.Remove($Name)
    if ($state.OnComplete) { & $state.OnComplete }
}

function Start-WinUtilJob {
    <#
        .SYNOPSIS
            Runs a long operation off the UI thread with the shared progress, taskbar, log and
            error handling applied around it

        .DESCRIPTION
            One job at a time. Owns the busy flag, the progress bar, the taskbar item, the
            console banner and the log lines for the job's lifetime. The body does the work and
            calls Step-WinUtilJob; it must not print a banner or set the busy flag itself. A body
            that throws is caught and the interface restored in a finally, so a failure cannot
            leave the UI stuck busy.

        .PARAMETER Name
            Log component and progress text, for example Install.

        .PARAMETER ScriptBlock
            The work. Receives Parameters as named parameters.

        .PARAMETER Parameters
            Values passed to the body by name.

        .PARAMETER Description
            Progress text shown while the job starts. Defaults to the job name.

        .PARAMETER DisableAppList
            Greys out the app list for the duration, for jobs that change what is installed.

        .EXAMPLE
            Start-WinUtilJob -Name "Install" -Parameters @{ Packages = $packages } -ScriptBlock {
                param($Packages)
                Step-WinUtilJob -Status "Installing" -Percent 10
            }
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock,

        [hashtable]$Parameters = @{},

        [string]$Description,

        [switch]$DisableAppList
    )

    if ($sync.ShuttingDown -or $sync.FinishInConsole) {
        Write-WinUtilLog -Level "WARN" -Component $Name -Message "Refused to start $Name, WinUtil is closing."
        return $null
    }

    # A nested job runs inline: the outer already owns the slot and the reporting, so claiming
    # again would refuse it and skip its work. Feature installs arrive twice, from feature.json
    # and from Invoke-WPFFeatureInstall.
    if ($global:WinUtilIsJobWorker) {
        & $ScriptBlock @Parameters
        return $null
    }

    # Locked: a headless or scheduled caller is not serialised by the dispatcher, where
    # test-then-assign lets two jobs both own the slot. The token identifies the run, so a worker
    # still unwinding cannot release a slot the next job holds.
    $jobToken = [guid]::NewGuid().ToString()
    $blockedBy = $null
    [System.Threading.Monitor]::Enter($sync.SyncRoot)
    try {
        if ($sync.ActiveJob) {
            $blockedBy = $sync.ActiveJob
        } else {
            $sync.ActiveJob = $Name
            $sync.ActiveJobToken = $jobToken
            $sync.LastJobResult = $null
        }
    } finally {
        [System.Threading.Monitor]::Exit($sync.SyncRoot)
    }

    if ($blockedBy) {
        Show-WinUtilMessage -Message "$blockedBy is still running. Wait for it to finish before starting another action." -Title "WinUtil" -Button "OK" -Icon "Warning" | Out-Null
        return $null
    }

    $label = if ($Description) { $Description } else { $Name }
    try {
        $timingStartIndex = if ($sync.StepTimings) { $sync.StepTimings.Count } else { 0 }

        Write-WinUtilLog -Component $Name -Message "$Name job started."
        Write-WinUtilJobBanner -Message $label
        Step-WinUtilJob -Status "$label..." -Percent 0 -State "Normal" -Overlay "logo"

        if ($DisableAppList -and (Test-WinUtilUIAlive)) {
            Invoke-WPFUIThread -ScriptBlock {
                if ($null -ne $sync.ItemsControl) { $sync.ItemsControl.IsEnabled = $false }
            }
        }

        # Rebuilt from its text inside the runspace: a scriptblock carries the session state it was
        # defined in, and recreating it there binds it to the worker. The handle is discarded,
        # printing it puts an IAsyncResult table on the console on every button press.
        $null = Invoke-WPFRunspace -ParameterList @(
            ("JobName", $Name),
            ("JobLabel", $label),
            ("JobBody", $ScriptBlock.ToString()),
            ("JobParameters", $Parameters),
            ("JobRestoresAppList", [bool]$DisableAppList),
            ("JobToken", $jobToken),
            ("TimingStartIndex", $timingStartIndex)
        ) -ScriptBlock {
        param($JobName, $JobLabel, $JobBody, $JobParameters, $JobRestoresAppList, $JobToken, $TimingStartIndex)

        # Marks this runspace as the one doing the work, so a pause holds here and not in
        # whoever asked for it
        $global:WinUtilIsJobWorker = $true
        $global:WinUtilJobErrorCount = 0
        $global:WinUtilJobWarningCount = 0

        $jobClock = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $body = [scriptblock]::Create($JobBody)

            # A worker's warning and error streams buffer on a PowerShell object nobody reads.
            # Merging them into the output stream is what gets them to the log.
            & $body @JobParameters 2>&1 3>&1 | ForEach-Object {
                if ($_ -is [System.Management.Automation.WarningRecord]) {
                    $global:WinUtilJobWarningCount++
                    Write-WinUtilLog -Level "WARN" -Component $JobName -Message $_.Message
                } elseif ($_ -is [System.Management.Automation.ErrorRecord]) {
                    Write-WinUtilErrorRecord -ErrorRecord $_ -Component $JobName -Context "Non-terminating error"
                }
            }

            $jobClock.Stop()

            # A step can fail without throwing, for example a registry write refused by policy.
            # The counter belongs to this worker runspace, so unrelated UI errors cannot change
            # this job's result while it is running.
            $newErrors = $global:WinUtilJobErrorCount
            $newWarnings = $global:WinUtilJobWarningCount
            if ($newErrors -gt 0) {
                Write-WinUtilLog -Level "WARN" -Component $JobName -Message "$JobName job finished in $($jobClock.ElapsedMilliseconds) ms with $newErrors error(s)."
                Write-WinUtilJobBanner -Message "$JobLabel finished with $newErrors error(s), see the log" -Level "ERROR"
                Step-WinUtilJob -Status "$JobName finished with $newErrors error(s)" -Percent 100 -State "Paused" -Overlay "warning"
            } elseif ($newWarnings -gt 0) {
                Write-WinUtilLog -Level "WARN" -Component $JobName -Message "$JobName job finished in $($jobClock.ElapsedMilliseconds) ms with $newWarnings warning(s)."
                Write-WinUtilJobBanner -Message "$JobLabel finished with $newWarnings warning(s), see the log"
                Step-WinUtilJob -Status "$JobName finished with $newWarnings warning(s)" -Percent 100 -State "Paused" -Overlay "warning"
            } else {
                Write-WinUtilLog -Component $JobName -Message "$JobName job finished in $($jobClock.ElapsedMilliseconds) ms."
                Write-WinUtilJobBanner -Message "$JobLabel finished"
                Step-WinUtilJob -Status "$JobName finished" -Percent 100 -State "None" -Overlay "checkmark"
            }
        } catch {
            $jobClock.Stop()
            # A leaf that logs before rethrowing marks that exact exception. Preserve the outer
            # context and stack without counting it twice; unrelated earlier errors do not qualify.
            $errorAlreadyReported = $_.Exception.Data["WinUtilErrorReported"] -eq $true
            Write-WinUtilErrorRecord -ErrorRecord $_ -Component $JobName -Context "$JobName failed after $($jobClock.ElapsedMilliseconds) ms" -DetailOnly:$errorAlreadyReported
            Write-WinUtilJobBanner -Message "$JobLabel failed: $($_.Exception.Message)" -Level "ERROR"
            Step-WinUtilJob -Status "$JobName failed" -Percent 100 -State "Error" -Overlay "warning"
        } finally {
            $jobResult = [pscustomobject]@{
                Token = $JobToken
                Errors = $global:WinUtilJobErrorCount
                Warnings = $global:WinUtilJobWarningCount
            }

            # Pool runspaces are reused, so leaving this set would make the next piece of
            # background work on this runspace believe it is a job worker
            $global:WinUtilIsJobWorker = $false
            $global:WinUtilJobErrorCount = 0
            $global:WinUtilJobWarningCount = 0

            Write-WinUtilTimingSummary -Scope $JobName -TotalMilliseconds $jobClock.ElapsedMilliseconds -StartIndex $TimingStartIndex

            # A worker the watchdog cut off can reach here after the next job claimed the slot,
            # and everything below releases shared state.
            $stillOwns = $false
            [System.Threading.Monitor]::Enter($sync.SyncRoot)
            try {
                $stillOwns = $sync.ActiveJobToken -eq $JobToken
                if ($stillOwns) {
                    $sync.LastJobResult = $jobResult
                }
            } finally {
                [System.Threading.Monitor]::Exit($sync.SyncRoot)
            }

            if ($stillOwns) {
                try {
                    if ($JobRestoresAppList -and (Test-WinUtilUIAlive)) {
                        Invoke-WPFUIThread -ScriptBlock {
                            if ($null -ne $sync.ItemsControl) { $sync.ItemsControl.IsEnabled = $true }
                        }
                    }
                } catch {
                    Write-WinUtilLog -Level "WARN" -Component $JobName -Message "Could not restore the app list after $JobName finished: $($_.Exception.Message)"
                } finally {
                    # Dispatcher shutdown can race the alive check and abort the restore call.
                    # The worker is still finished, so its slot must always be released.
                    $null = Clear-WinUtilActiveJob -Token $JobToken
                }
            } else {
                Write-WinUtilLog -Level "WARN" -Component $JobName -Message "$JobName unwound after another job had started; leaving its state alone."
            }
        }
        }
    } catch {
        $scheduleError = $_
        try {
            Write-WinUtilErrorRecord -ErrorRecord $scheduleError -Component $Name -Context "Could not schedule $Name"
            $sync.LastJobResult = [pscustomobject]@{ Token = $jobToken; Errors = 1; Warnings = 0 }
            Write-WinUtilJobBanner -Message "$label could not start" -Level "ERROR"
            Step-WinUtilJob -Status "$Name could not start" -Percent 100 -State "Error" -Overlay "warning"
        } catch {
            Write-WinUtilLog -Level "WARN" -Component $Name -Message "Could not report that $Name failed to start: $($_.Exception.Message)"
        } finally {
            try {
                if ($DisableAppList -and (Test-WinUtilUIAlive)) {
                    Invoke-WPFUIThread -ScriptBlock {
                        if ($null -ne $sync.ItemsControl) { $sync.ItemsControl.IsEnabled = $true }
                    }
                }
            } catch {
                Write-WinUtilLog -Level "WARN" -Component $Name -Message "Could not restore the app list after $Name failed to start: $($_.Exception.Message)"
            } finally {
                $null = Clear-WinUtilActiveJob -Token $jobToken
            }
        }
    }
}

function Clear-WinUtilActiveJob {
    <#
        .SYNOPSIS
            Releases the active job slot, clearing its name and its token together

        .DESCRIPTION
            A token left set still matches a later run and blocks new work.

        .PARAMETER Token
            Release only if this run still owns the slot. Omit to release unconditionally.
    #>
    param([string]$Token)

    [System.Threading.Monitor]::Enter($sync.SyncRoot)
    try {
        if (-not $Token -or $sync.ActiveJobToken -eq $Token) {
            $sync.ActiveJobToken = $null
            $sync.ActiveJob = $null
            return $true
        }
        return $false
    } finally {
        [System.Threading.Monitor]::Exit($sync.SyncRoot)
    }
}

function Start-WinUtilUserInterface {
    <#
        .SYNOPSIS
            Builds the WinUtil window, wires its event handlers and runs it to completion

        .DESCRIPTION
            This is the whole interface. It runs on the dedicated STA interface runspace that
            main.ps1 starts, so the thread that owns the window does nothing but paint and
            dispatch: every long operation goes to the worker pool through Start-WinUtilJob.

            The call blocks until the window is closed, and the interface runspace is the only
            place that is allowed to touch controls directly.
    #>

    $buildClock = [System.Diagnostics.Stopwatch]::StartNew()

    Measure-WinUtilStep -Scope "UI" -Name "load WPF assemblies" -ScriptBlock {
        [void][System.Reflection.Assembly]::LoadWithPartialName('presentationframework')
    }

    [xml]$XAML = $inputXML

    # Read the XAML file
    $readerOperationSuccessful = $false # There's more cases of failure then success.
    $readerFailure = $null
    $reader = (New-Object System.Xml.XmlNodeReader $xaml)
    try {
        Measure-WinUtilStep -Scope "UI" -Name "parse XAML" -ScriptBlock {
            $sync["Form"] = [Windows.Markup.XamlReader]::Load( $reader )
        }
        $readerOperationSuccessful = $true
    } catch [System.Management.Automation.MethodInvocationException] {
        $readerFailure = $_
        Write-Host "We ran into a problem with the XAML code.  Check the syntax for this control..." -ForegroundColor Red
        Write-Host $error[0].Exception.Message -ForegroundColor Red

        If ($error[0].Exception.Message -like "*button*") {
            write-Host "Ensure your &lt;button in the `$inputXML does NOT have a Click=ButtonClick property.  PS can't handle this`n`n`n`n" -ForegroundColor Red
        }
    } catch {
        $readerFailure = $_
        Write-Host "Unable to load Windows.Markup.XamlReader. Double-check syntax and ensure .net is installed." -ForegroundColor Red
    }

    if (-NOT ($readerOperationSuccessful)) {
        Write-Host "Failed to parse xaml content using Windows.Markup.XamlReader's Load Method." -ForegroundColor Red
        Write-Host "Quitting WinUtil..." -ForegroundColor Red
        Write-WinUtilLog -Level "ERROR" -Component "UI" -Message "Failed to parse the XAML content. WinUtil cannot start."
        throw [System.InvalidOperationException]::new("Failed to parse the XAML content. WinUtil cannot start.", $readerFailure.Exception)
    }

    # Setup the Window to follow listen for windows Theme Change events and update the winutil theme
    # throttle logic needed, because windows seems to send more than one theme change event per change
    $themeState = @{ LastChange = [datetime]::MinValue }
    $debounceInterval = [timespan]::FromSeconds(2)
    $sync.Form.Add_Loaded({
        $interopHelper = New-Object System.Windows.Interop.WindowInteropHelper $sync.Form
        $hwndSource = [System.Windows.Interop.HwndSource]::FromHwnd($interopHelper.Handle)
        $hwndSource.AddHook({
            param (
                [System.IntPtr]$hwnd,
                [int]$msg,
                [System.IntPtr]$wParam,
                [System.IntPtr]$lParam,
                [ref]$handled
            )
            $null = $hwnd, $wParam, $lParam
            # Check for the Event WM_SETTINGCHANGE (0x1001A) and validate that Button shows the icon for "Auto" => [char]0xF08C
            if (($msg -eq 0x001A) -and $sync.ThemeButton.Content -eq [char]0xF08C) {
                $currentTime = [datetime]::Now
                if ($currentTime - $themeState.LastChange -gt $debounceInterval) {
                    Invoke-WinutilThemeChange -theme "Auto"
                    $themeState.LastChange = $currentTime
                    # [ref] out-parameter: assigning to $handled would only replace the local
                    $handled.Value = $true
                }
            }
            return 0
        })
    })

    Measure-WinUtilStep -Scope "UI" -Name "apply theme" -ScriptBlock {
        Invoke-WinutilThemeChange -theme $sync.preferences.theme
    }

    # No tab content is built before first paint. Invoke-WPFTab builds whichever tab it
    # activates, and ContentRendered activates the default one.
    $sync.InitializedTabs = @{}

    #===========================================================================
    # Store Form Objects In PowerShell
    #===========================================================================

    Measure-WinUtilStep -Scope "UI" -Name "map named controls" -ScriptBlock {
        $xaml.SelectNodes("//*[@Name]") | ForEach-Object {$sync["$("$($psitem.Name)")"] = $sync["Form"].FindName($psitem.Name)}
    }
    Initialize-WinUtilLanguage
    Update-WinUtilLanguageUI

    # Built here so it carries this runspace's session state: posted work then runs as ordinary
    # interface code, not a much slower cross-runspace nested pipeline. Invoke-WPFUIThread is the
    # caller-facing side.
    $sync.UIDispatchDelegate = [System.Func[object, object]]{
        param($Work)

        try {
            $body = [scriptblock]::Create($Work.Body)
            $parameters = $Work.Parameters
            if ($parameters -and $parameters.Count -gt 0) {
                & $body @parameters
            } else {
                & $body
            }
        } catch {
            if ($Work.PropagateErrors) {
                throw
            }
            # Fire-and-forget work has no waiting caller to report its failure.
            Write-WinUtilErrorRecord -ErrorRecord $_ -Component "UI" -Context "Interface work"
        }
    }

    Measure-WinUtilStep -Scope "UI" -Name "wire static button clicks" -ScriptBlock {
        # CheckBox and RadioButton also derive from ButtonBase, so the exact type name is what
        # decides, not -is
        $clickableTypes = [System.Collections.Generic.HashSet[string]]::new([string[]]@("Button", "ToggleButton"), [StringComparer]::OrdinalIgnoreCase)
        $alreadyWired = [System.Collections.Generic.HashSet[string]]::new([string[]]@($sync.Buttons), [StringComparer]::OrdinalIgnoreCase)

        $clickHandler = {
            [System.Object]$Sender = $args[0]
            Invoke-WPFButton $Sender.name
        }

        foreach ($entry in @($sync.GetEnumerator())) {
            $control = $entry.Value
            if ($null -eq $control -or -not $clickableTypes.Contains($control.GetType().Name)) {
                continue
            }
            if (-not $alreadyWired.Add([string]$entry.Key)) {
                continue
            }

            $control.Add_Click($clickHandler)
            $sync.Buttons.Add($entry.Key) | Out-Null
        }
    }

    #===========================================================================
    # Setup and Show the Form
    #===========================================================================

    # Progress bar in taskbaritem > Set-WinUtilProgressbar
    $sync["Form"].TaskbarItemInfo = New-Object System.Windows.Shell.TaskbarItemInfo
    Set-WinUtilTaskbaritem -state "None"

    # Wired before the window is shown, so work queued during startup already knows to stand
    # aside for anything the user does
    Register-WinUtilInputWatch

    # Set the titlebar
    $sync["Form"].title = $sync["Form"].title + " " + $sync.version
    # Set the commands that will run when the form is closed
    $sync["Form"].Add_Closing({
        param($eventSender, $closingArgs)
        $null = $eventSender

        # The pool cannot be torn down under work that is still running: the runspace error that
        # follows is unhandled and ends the process
        if ($sync.ActiveJob -and -not $sync.ForceClose) {
            $closingArgs.Cancel = $true
            Invoke-WinUtilCloseRequest -RunningJob $sync.ActiveJob
            return
        }

        # Work that is meant to outlive the window needs the pool it is running on. main.ps1
        # waits for it and shuts the pool down once it is done.
        if ($sync.FinishInConsole) {
            Write-WinUtilLog -Component "UI" -Message "Window closing, leaving $($sync.ActiveJob) to finish in the console."
            return
        }

        # main.ps1 owns pool shutdown after the window has finished closing. Doing it from this
        # dispatcher callback can deadlock with a worker that is in its UI-thread cleanup block.
        Write-WinUtilLog -Component "UI" -Message "Window closing; the main thread will shut down the worker pool."
    })

    # Attach the event handler to the Click event
    $sync.SearchBarClearButton.Add_Click({
        $sync.SearchBar.Text = ""
        $sync.SearchBarClearButton.Visibility = "Collapsed"

        # Focus the search bar after clearing the text
        $sync.SearchBar.Focus()
        $sync.SearchBar.SelectAll()
    })

    # add some shortcuts for people that don't like clicking
    function Invoke-WinUtilFontScaleStep([double]$Step) { $sync.FontScalingSlider.Value = [math]::Max(0.75, [math]::Min(2.0, $sync.FontScalingSlider.Value + $Step)); Invoke-WinUtilFontScaling -ScaleFactor $sync.FontScalingSlider.Value }

    $commonKeyEvents = {
        if ($sync.ActiveJob) {
            return
        }

        # Handle key presses of single keys
        switch ($_.Key) {
            "Escape" { $sync.SearchBar.Text = "" }
        }
        # Handle Alt key combinations for navigation
        if ($_.KeyboardDevice.Modifiers -eq "Alt") {
            $keyEventArgs = $_
            switch ($_.SystemKey) {
                "T" { Invoke-WPFButton "WPFTab2BT"; $keyEventArgs.Handled = $true } # Navigate to Tweaks tab
                "A" { Invoke-WPFButton "WPFAdvancedTabBT"; $keyEventArgs.Handled = $true } # Navigate to Advanced
            }
        }
        # Handle Ctrl key combinations for specific actions
        if ($_.KeyboardDevice.Modifiers -eq "Ctrl") {
            $keyEventArgs = $_
            switch ($_.Key) {
                "F" { if ($sync.currentTab -ne 'Tweaks') { Invoke-WPFTab 'WPFTab2BT' }; $sync.SearchBar.Focus() } # Focus on Tweaks search
                "Q" { $this.Close() } # Close the application
            }
        }
        $ctrlShiftModifiers = [Windows.Input.ModifierKeys]::Control -bor [Windows.Input.ModifierKeys]::Shift
        if ($_.KeyboardDevice.Modifiers -eq "Ctrl" -or $_.KeyboardDevice.Modifiers -eq $ctrlShiftModifiers) {
            $keyEventArgs = $_
            switch ($_.Key) {
                { $_ -in "OemPlus", "Add" } { Invoke-WinUtilFontScaleStep 0.05; $keyEventArgs.Handled = $true }
                { $_ -in "OemMinus", "Subtract" } { Invoke-WinUtilFontScaleStep -0.05; $keyEventArgs.Handled = $true }
            }
        }
    }
    $sync["Form"].Add_PreViewKeyDown($commonKeyEvents)
    $sync["Form"].Add_PreviewMouseWheel({
        if ([Windows.Input.Keyboard]::Modifiers -eq "Ctrl") { Invoke-WinUtilFontScaleStep $(if ($_.Delta -gt 0) { 0.05 } else { -0.05 }); $_.Handled = $true }
    })

    $sync["Form"].Add_MouseLeftButtonDown({
        Invoke-WPFPopup -Action "Hide" -Popups @("Settings", "Theme", "FontScaling")
        $sync["Form"].DragMove()
    })

    $sync["Form"].Add_MouseDoubleClick({
        if ($_.OriginalSource.Name -eq "NavDockPanel" -or
            $_.OriginalSource.Name -eq "GridBesideNavDockPanel") {
                if ($sync["Form"].WindowState -eq [Windows.WindowState]::Normal) {
                    [Windows.SystemCommands]::MaximizeWindow($sync.Form)
                }
                else{
                    [Windows.SystemCommands]::RestoreWindow($sync.Form)
                }
        }
    })

    $sync["Form"].Add_Deactivated({
        Invoke-WPFPopup -Action "Hide" -Popups @("Settings", "Theme", "FontScaling")
    })

    $sync["Form"].Add_ContentRendered({
        # Load the Windows Forms assembly
        Add-Type -AssemblyName System.Windows.Forms
        $primaryScreen = [System.Windows.Forms.Screen]::PrimaryScreen
        # Check if the primary screen is found
        if ($primaryScreen) {
            # Extract screen width and height for the primary monitor
            $screenWidth = $primaryScreen.Bounds.Width
            $screenHeight = $primaryScreen.Bounds.Height
            $sync.Form.MinWidth = [Math]::Min([double]$sync.Form.MinWidth, [double]$screenWidth)

            # Compare with the primary monitor size
            if ($sync.Form.ActualWidth -gt $screenWidth -or $sync.Form.ActualHeight -gt $screenHeight) {
                $sync.Form.Left = 0
                $sync.Form.Top = 0
                $sync.Form.Width = $screenWidth
                $sync.Form.Height = $screenHeight
            }
        }

        if ($PARAM_OFFLINE) {
            $sync.WPFOfflineBanner.Visibility = [System.Windows.Visibility]::Visible
        }
        Invoke-WPFTab 'WPFTab2BT' -Yield
        # "Review in advanced mode" from the guided window marks its plan here.
        if ($sync.GuidedReviewPlan) {
            try { Complete-WinUtilGuidedReview } catch { Write-WinUtilErrorRecord -ErrorRecord $_ -Component 'Guided' -Context 'Review guided plan' }
        }
        $sync["Form"].Focus()
        $sync["Form"].Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [action]{ Initialize-WinUtilRunspacePool | Out-Null }) | Out-Null
        $sync["Form"].Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [action]{
            Set-WinUtilTaskbaritem -overlay "logo"
        }) | Out-Null
    })

    # The SearchBarTimer is used to delay the search operation until the user has stopped typing for a short period
    # This prevents the ui from stuttering when the user types quickly as it dosnt need to update the ui for every keystroke

    $searchBarTimer = New-Object System.Windows.Threading.DispatcherTimer
    $searchBarTimer.Interval = [TimeSpan]::FromMilliseconds(300)
    $searchBarTimer.IsEnabled = $false

    $searchBarTimer.add_Tick({
        $searchBarTimer.Stop()
        Find-TweaksByNameOrDescription -SearchString $sync.SearchBar.Text
    })
    $sync["SearchBar"].Add_TextChanged({
        if ($sync.SearchBar.Text -ne "") {
            $sync.SearchBarClearButton.Visibility = "Visible"
            $sync.SearchBarIcon.Visibility = "Collapsed"
        } else {
            $sync.SearchBarClearButton.Visibility = "Collapsed"
            $sync.SearchBarIcon.Visibility = "Visible"
        }

        if ($searchBarTimer.IsEnabled) {
            $searchBarTimer.Stop()
        }
        $searchBarTimer.Start()
    })


    $sync["Form"].Add_Loaded({
        param($e)
        $null = $e
        $sync.Form.MinWidth = "1150"
        $sync["Form"].MaxWidth = [Double]::PositiveInfinity
        $sync["Form"].MaxHeight = [Double]::PositiveInfinity
    })

    Measure-WinUtilStep -Scope "UI" -Name "build nav logo" -ScriptBlock {
        $NavLogoPanel = $sync["Form"].FindName("NavLogoPanel")
        $NavLogoPanel.Children.Add((Invoke-WinUtilAssets -Type "logo" -Size 25)) | Out-Null
    }

    $sync["Form"].Add_Activated({
        Set-WinUtilTaskbaritem -overlay "logo"
    })

    $sync["ThemeButton"].Add_Click({
        Invoke-WPFPopup -PopupActionTable @{ "Settings" = "Hide"; "Theme" = "Toggle"; "FontScaling" = "Hide" }
    })
    $sync["AutoThemeMenuItem"].Add_Click({
        Invoke-WPFPopup -Action "Hide" -Popups @("Theme")
        Invoke-WinutilThemeChange -theme "Auto"
    })
    $sync["DarkThemeMenuItem"].Add_Click({
        Invoke-WPFPopup -Action "Hide" -Popups @("Theme")
        Invoke-WinutilThemeChange -theme "Dark"
    })
    $sync["LightThemeMenuItem"].Add_Click({
        Invoke-WPFPopup -Action "Hide" -Popups @("Theme")
        Invoke-WinutilThemeChange -theme "Light"
    })

    $sync["SettingsButton"].Add_Click({
        Invoke-WPFPopup -PopupActionTable @{ "Settings" = "Toggle"; "Theme" = "Hide"; "FontScaling" = "Hide" }
    })
    $sync["WPFLanguageSelector"].Add_SelectionChanged({
        if ($sync.LanguageSelectorChanging -or $null -eq $sync.WPFLanguageSelector.SelectedItem) { return }
        $chosenLanguage = [string]$sync.WPFLanguageSelector.SelectedItem.Tag
        Set-WinUtilLanguage -Language $chosenLanguage
    })
    $sync["ImportMenuItem"].Add_Click({
        Invoke-WPFPopup -Action "Hide" -Popups @("Settings")
        Invoke-WPFImpex -type "import"
    })
    $sync["ExportMenuItem"].Add_Click({
        Invoke-WPFPopup -Action "Hide" -Popups @("Settings")
        Invoke-WPFImpex -type "export"
    })

    $sync["GuidedModeMenuItem"].Add_Click({
        Invoke-WPFPopup -Action "Hide" -Popups @("Settings")
        try {
            $null = Show-WinUtilGuidedWindow -Start 'Resume' -Owner $sync.Form
            if ($sync.GuidedReviewPlan) { Complete-WinUtilGuidedReview }
        } catch {
            Write-WinUtilErrorRecord -ErrorRecord $_ -Component 'Guided' -Context 'Open guided mode'
        }
    })

    $sync["AboutMenuItem"].Add_Click({
        Invoke-WPFPopup -Action "Hide" -Popups @("Settings")

        $title = if ($sync.Language -eq 'es') { 'Acerca de APBOptimizer' } else { 'About APBOptimizer' }
        $authorInfo = Get-WinUtilAboutInfo -Language $sync.Language -Version $sync.version
        Show-CustomDialog -Title $title -Message $authorInfo -HeaderText 'APBOptimizer' -Width 640 -Height 490 -EnableScroll $true
    })

    # Font Scaling Event Handlers
    $sync["FontScalingButton"].Add_Click({
        Invoke-WPFPopup -PopupActionTable @{ "Settings" = "Hide"; "Theme" = "Hide"; "FontScaling" = "Toggle" }
    })

    $sync["FontScalingSlider"].Add_ValueChanged({
        param($slider)
        $percentage = [math]::Round($slider.Value * 100)
        $sync.FontScalingValue.Text = "$percentage%"
    })

    $sync["FontScalingResetButton"].Add_Click({
        $sync.FontScalingSlider.Value = 1.0
        $sync.FontScalingValue.Text = "100%"
    })

    $sync["FontScalingApplyButton"].Add_Click({
        $scaleFactor = $sync.FontScalingSlider.Value
        Invoke-WinUtilFontScaling -ScaleFactor $scaleFactor
        Invoke-WPFPopup -Action "Hide" -Popups @("FontScaling")
    })


    $buildClock.Stop()
    Write-WinUtilLog -Level "DEBUG" -Component "UI" -Message "Interface built in $($buildClock.ElapsedMilliseconds) ms, showing the window."
    Write-WinUtilTimingSummary -Scope "UI" -TotalMilliseconds $buildClock.ElapsedMilliseconds

    # Input priority runs behind everything already queued, so this fires at the first moment
    # the window could actually service a click
    $sync["Form"].Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Input, [action]{
        $sinceStart = [int]((Get-Date) - $sync.StartedAt).TotalMilliseconds
        Write-WinUtilLog -Level "DEBUG" -Component "UI" -Message "timing: interface ready for input $sinceStart ms after start."
    }) | Out-Null

    # The guided window is a separate launcher. The full interface opens only when the user
    # picks advanced mode there.
    try {
        $openMain = Show-WinUtilGuidedWindow -Start 'Chooser'
    } catch {
        Write-WinUtilErrorRecord -ErrorRecord $_ -Component 'Guided' -Context 'Show guided window'
        $openMain = $true
    }
    if ($openMain) {
        $sync["Form"].ShowDialog() | Out-Null
    }

    # ShowDialog returns once the window is gone; stop the dispatcher so this runspace can close
    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown()
}

function Step-WinUtilJob {
    <#
        .SYNOPSIS
            Advances a job to its next reportable point, honouring a pause or stop on the way

        .DESCRIPTION
            Every loop calls this, so it is the one point a run reliably passes between steps and
            therefore the only place it can be held or ended without cutting into a command in
            flight. It blocks while the run is paused and throws OperationCanceledException once
            a stop is asked for, so calling it from a finally, or from a catch already reporting
            a failure, re-raises that stop. The job layer clears the flags before its own finish
            reporting for that reason.

            Drives the progress bar and taskbar item together and does nothing without a window,
            so job bodies need no UI checks. The update is posted rather than waited on: a job
            reporting per item would otherwise stall on the interface thread each time.

        .PARAMETER Status
            Text for the progress label

        .PARAMETER Percent
            Completion between 0 and 100

        .PARAMETER State
            Taskbar state. Normal while working, Error on failure, None when finished.

        .PARAMETER Overlay
            Taskbar overlay icon: logo, checkmark, warning or None

        .PARAMETER Hide
            Clears and hides the progress bar. Used when leaving a finished job behind rather
            than while one is running.
    #>
    param(
        [string]$Status,
        [int]$Percent = -1,
        [ValidateSet("Normal", "Error", "Paused", "Indeterminate", "None")]
        [string]$State,
        [string]$Overlay,
        [switch]$Hide
    )

    # With no window every update is thrown away, and a window closed over running work counts
    # as none: its dispatcher accepts posts and discards them. The console is what is left.
    if (-not (Test-WinUtilUIAlive)) {
        if (-not $Hide) {
            Write-WinUtilConsoleProgress -Status $Status -Percent $Percent
        }
        return
    }

    Invoke-WPFUIThread -Async -Parameters @{
        Status = $Status
        Percent = [Math]::Min([Math]::Max($Percent, -1), 100)
        State = $State
        Overlay = $Overlay
        HideBar = [bool]$Hide
        HasStatus = $PSBoundParameters.ContainsKey('Status')
        HasState = $PSBoundParameters.ContainsKey('State')
        HasOverlay = $PSBoundParameters.ContainsKey('Overlay')
    } -ScriptBlock {
        param($Status, $Percent, $State, $Overlay, $HideBar, $HasStatus, $HasState, $HasOverlay)

        if ($HideBar) {
            $sync.WPFTweaksProgressBar.Visibility = [Windows.Visibility]::Collapsed
            $sync.WPFTweaksProgressLabel.Text = ""
            $sync.WPFTweaksProgressLabel.ToolTip = $null
            $sync.WPFTweaksProgressValue.Value = 0
            return
        }

        $hasPercent = $Percent -ge 0

        if ($HasStatus -or $hasPercent) {
            $sync.WPFTweaksProgressBar.Visibility = [Windows.Visibility]::Visible
        }
        if ($HasStatus) {
            $sync.WPFTweaksProgressLabel.Text = $Status
            $sync.WPFTweaksProgressLabel.ToolTip = $Status
        }
        if ($hasPercent) {
            $sync.WPFTweaksProgressValue.Value = $Percent
            $sync.Form.TaskbarItemInfo.ProgressValue = $Percent / 100
        }
        if ($HasState) {
            # Pulse in place at whatever progress has been reached. IsIndeterminate would make
            # WPF discard Value and fill the whole bar, which reads as finished.
            $sync.WPFTweaksProgressValue.Tag = if ($State -eq "Indeterminate") { "Pulse" } else { $null }

            # By resource reference rather than a fixed brush, so switching theme repaints it
            $barColor = switch ($State) {
                "Error"  { "ProgressBarErrorColor" }
                "Paused" { "ProgressBarWarningColor" }
                default  { "ProgressBarForegroundColor" }
            }
            $sync.WPFTweaksProgressValue.SetResourceReference([Windows.Controls.Control]::ForegroundProperty, $barColor)

            Set-WinUtilTaskbaritem -state $State
        }
        if ($HasOverlay) {
            Set-WinUtilTaskbaritem -overlay $Overlay
        }
    }
}

function Test-WinUtilShellRunning {
    <#
        .SYNOPSIS
            Whether one instance is still running, treating a disposed one as finished
    #>
    param($PowerShell)

    try {
        return $PowerShell.InvocationStateInfo.State -in @(
            [System.Management.Automation.PSInvocationState]::Running,
            [System.Management.Automation.PSInvocationState]::Stopping
        )
    } catch {
        return $false
    }
}

function Register-WinUtilActiveShell {
    <#
        .SYNOPSIS
            Records a PowerShell instance that is running on the worker pool

        .DESCRIPTION
            An instance still queued when the pool closes starts on a closing runspace, throws on
            a thread pool thread where nothing catches, and takes the process down with it.
            Tracking what is in flight is what lets those be stopped first.
    #>
    param(
        [Parameter(Mandatory)]
        $PowerShell
    )

    # Synchronized protects one operation, not a test followed by an assignment, so the
    # collection is created under the shared lock
    [System.Threading.Monitor]::Enter($sync.SyncRoot)
    try {
        if ($null -eq $sync.ActiveShells) {
            $sync.ActiveShells = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new())
        }
    } finally {
        [System.Threading.Monitor]::Exit($sync.SyncRoot)
    }

    # Nothing disposes these on the way out, so finished ones are dropped here instead of
    # accumulating for the life of the session
    foreach ($finished in (Get-WinUtilActiveShell)) {
        if (-not (Test-WinUtilShellRunning $finished)) {
            try {
                $sync.ActiveShells.Remove($finished)
            } catch {
                Write-WinUtilLog -Level "WARN" -Component "UI" -Message "Could not remove a completed worker from the active set: $_"
            }
        }
    }

    $null = $sync.ActiveShells.Add($PowerShell)
}

function Get-WinUtilActiveShell {
    <#
        .SYNOPSIS
            A snapshot of the tracked instances, copied under the collection's own lock

        .DESCRIPTION
            Enumerating a synchronized ArrayList is not itself synchronized; a concurrent Add or
            Remove throws mid-loop. SyncRoot is the documented fix.
    #>

    if ($null -eq $sync.ActiveShells) {
        return @()
    }

    [System.Threading.Monitor]::Enter($sync.ActiveShells.SyncRoot)
    try {
        return @($sync.ActiveShells.ToArray())
    } finally {
        [System.Threading.Monitor]::Exit($sync.ActiveShells.SyncRoot)
    }
}

function Stop-WinUtilActiveWork {
    <#
        .SYNOPSIS
            Asks everything running on the worker pool to stop, and waits for it

        .DESCRIPTION
            Stop is a request, not a kill: a command already inside an installer runs until it
            returns. The wait is bounded so a worker that never returns cannot hold the window
            open.

        .PARAMETER TimeoutSeconds
            How long to wait before giving up on it.
    #>
    param(
        [int]$TimeoutSeconds = 15,

        # Issue the stop and return. The caller polls Test-WinUtilActiveWorkRunning instead of
        # blocking here, which matters on the interface thread where a wait freezes the window.
        [switch]$NoWait
    )

    $shells = Get-WinUtilActiveShell
    if ($shells.Count -eq 0) {
        return $true
    }

    Write-WinUtilLog -Component "UI" -Message "Stopping $($shells.Count) running item(s) before closing."

    foreach ($shell in $shells) {
        if (Test-WinUtilShellRunning $shell) {
            try {
                $null = $shell.BeginStop($null, $null)
            } catch {
                Write-WinUtilLog -Level "WARN" -Component "UI" -Message "Could not request that a worker stop: $_"
            }
        }
    }

    if ($NoWait) {
        return $false
    }

    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    while ($clock.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $stillRunning = @(Get-WinUtilActiveShell | Where-Object { Test-WinUtilShellRunning $_ }).Count

        if ($stillRunning -eq 0) {
            Write-WinUtilLog -Component "UI" -Message "Everything stopped after $($clock.ElapsedMilliseconds) ms."
            return $true
        }

        Start-Sleep -Milliseconds 100
    }

    Write-WinUtilLog -Level "WARN" -Component "UI" -Message "Gave up waiting for work to stop after $TimeoutSeconds seconds, closing anyway."
    return $false
}

function Test-WinUtilActiveWorkRunning {
    <#
        .SYNOPSIS
            Whether any tracked instance is still running
    #>

    foreach ($shell in (Get-WinUtilActiveShell)) {
        if (Test-WinUtilShellRunning $shell) { return $true }
    }

    return $false
}

function Register-WinUtilInputWatch {
    <#
        .SYNOPSIS
            Records when the user last did something, so background work can step aside

        .DESCRIPTION
            Preview events run before the control handles the input, so the timestamp is set
            even for a click the control then spends time on.
    #>

    $sync.LastInputAt = [datetime]::MinValue

    $stamp = { $sync.LastInputAt = [datetime]::Now }
    $sync.Form.Add_PreviewMouseDown($stamp)
    $sync.Form.Add_PreviewKeyDown($stamp)
    $sync.Form.Add_PreviewMouseWheel($stamp)
}

function Test-WinUtilDeferBackgroundWork {
    <#
        .SYNOPSIS
            Whether speculative work should wait rather than run now

        .DESCRIPTION
            Background priority queues work behind input but does not make it interruptible:
            whatever is running must finish before a click is looked at, which is why the pieces
            are kept short. Waits while the user is active, or while the work draws into a tab
            that is not on screen.

        .PARAMETER RequiresTab
            The tab this work draws into. Work for a hidden tab waits.
    #>
    param(
        [string]$RequiresTab
    )

    if ($sync.LastInputAt) {
        $sinceInput = ([datetime]::Now - $sync.LastInputAt).TotalMilliseconds
        # long enough to cover a click and the work it starts, short enough not to be noticed
        if ($sinceInput -lt 400) {
            return $true
        }
    }

    if ($RequiresTab -and $sync.currentTab -and $sync.currentTab -ne $RequiresTab) {
        return $true
    }

    return $false
}

function Invoke-WinUtilWhenIdle {
    <#
        .SYNOPSIS
            Runs a callback once the interface is not being used

        .DESCRIPTION
            A one shot timer, not a dispatcher post: a post at background priority runs straight
            away and the point is to leave a gap.

        .PARAMETER Callback
            What to run once the wait is over.

        .PARAMETER Argument
            Passed to the callback. Carried on the timer rather than captured, so the callback
            resolves commands where it was written, not in a copied scope.

        .PARAMETER DelayMilliseconds
            How long to wait before looking again.
    #>
    param(
        [Parameter(Mandatory)]
        [scriptblock]$Callback,

        $Argument,

        [int]$DelayMilliseconds = 150
    )

    if (-not (Test-WinUtilUIAlive)) {
        return
    }

    # Bound to the interface dispatcher explicitly: the default picks up the calling thread's,
    # which is only correct while every caller reaches here through a UI post
    $timer = New-Object System.Windows.Threading.DispatcherTimer([System.Windows.Threading.DispatcherPriority]::Background, $sync.Form.Dispatcher)
    $timer.Interval = [timespan]::FromMilliseconds($DelayMilliseconds)
    $timer.Tag = @{ Callback = $Callback; Argument = $Argument }
    # Sender taken from the argument, matching how the rest of this codebase handles timer ticks
    $timer.Add_Tick({
        param($eventSender)
        $ticked = [System.Windows.Threading.DispatcherTimer]$eventSender
        $ticked.Stop()
        & $ticked.Tag.Callback $ticked.Tag.Argument
    })
    $timer.Start()
}

function Update-WinUtilSelections {
    param(
        [Parameter(Mandatory)]
        [string[]]$flatJson,

        [switch]$Replace,

        [switch]$SkipUnknown
    )

    $nextSelections = @{
        selectedTweaks   = [System.Collections.Generic.List[string]]::new()
        selectedToggles  = [System.Collections.Generic.List[string]]::new()
    }

    # Older exports represented exactly five tasks with one checkbox. Keep
    # those same five selections; newly added tasks remain opt-in.
    $flatJson = @($flatJson | ForEach-Object {
        if ($_ -eq 'WPFTweaksDisableTelemetryTasks') {
            @(
                'WPFToggleTaskCompatibilityAppraiser'
                'WPFToggleTaskProgramDataUpdater'
                'WPFToggleTaskConsolidator'
                'WPFToggleTaskUsbCeip'
                'WPFToggleTaskKernelCeip'
            )
        } else { $_ }
    })

    foreach ($cbkey in $flatJson) {

        $listName = switch -Regex ($cbkey) {
            '^WPFTweaks'  { 'selectedTweaks' }
            '^WPFToggle'  { 'selectedToggles' }
        }

        if (-not $listName) {
            if ($SkipUnknown) {
                $cbkey
                continue
            }
            throw "Unsupported selection key '$cbkey'."
        }

        $isKnownSelection = switch ($listName) {
            'selectedTweaks' {
                $null -ne $sync.configs.tweaks.PSObject.Properties[$cbkey]
            }
            'selectedToggles' {
                $null -ne $sync.configs.tweaks.PSObject.Properties[$cbkey]
            }
        }

        if (-not $isKnownSelection) {
            if ($SkipUnknown) {
                $cbkey
                continue
            }
            throw "Unknown selection key '$cbkey'."
        }

        # A replacement import can contain repeated identifiers. Keep a single
        # selection so each tweak or toggle runs at most once per Apply.
        if ($nextSelections[$listName] -notcontains $cbkey) {
            $nextSelections[$listName].Add($cbkey)
        }
    }

    $validSelectionCount = ($nextSelections.Values | ForEach-Object { $_.Count } | Measure-Object -Sum).Sum
    if ($SkipUnknown -and $validSelectionCount -eq 0) {
        return
    }

    if ($Replace) {
        foreach ($listName in $nextSelections.Keys) {
            $sync[$listName] = $nextSelections[$listName]
        }
        return
    }

    foreach ($listName in $nextSelections.Keys) {
        foreach ($cbkey in $nextSelections[$listName]) {
            # Appending, so the same entry can already be there: a preset and a config that both
            # name it would otherwise select it twice
            if ($sync.$listName -notcontains $cbkey) {
                $sync.$listName.Add($cbkey)
            }
        }
    }
}

function Update-WinUtilServiceGroupMaster {
    param([Parameter(Mandatory)][string]$GroupName)

    $master = $sync[$GroupName]
    if ($null -eq $master -or $master.Tag.Updating) { return }

    $available = 0
    $checked = 0
    foreach ($key in @($master.Tag.Children)) {
        $child = $sync[$key]
        if ($null -eq $child -or -not $child.IsEnabled) { continue }
        $available++
        if ($child.IsChecked -eq $true) { $checked++ }
    }

    # Null is a visual mixed state; IsThreeState stays false so the next user
    # click still means a binary bulk action.
    # A driver group whose installed drivers are all already disabled shows
    # that real state instead of an unchecked, apparently active header.
    $state = if ($available -eq 0) { [bool]$master.Tag.AllAlreadyDisabled }
             elseif ($checked -eq 0) { $false }
             elseif ($checked -eq $available) { $true }
             else { $null }
    $master.Tag.Updating = $true
    try {
        # If every driver is already disabled/protected/absent, allow clicking
        # the header to see an explanation rather than leaving an inert control.
        $master.IsEnabled = ($available -gt 0 -or [bool]$master.Tag.NoManageableDrivers)
        $master.IsChecked = $state
    } finally {
        $master.Tag.Updating = $false
    }
}

function Update-WinUtilServiceGroupState {
    <#

    .SYNOPSIS
        Re-reads grouped service startup types after a tweak run

    .DESCRIPTION
        Other tweaks (Telemetry, Services) change the same services, and a failed
        group change leaves Windows as it was. Without a refresh the cached baseline
        and the checkboxes keep showing the state from when the panel was built.
        Entries with a pending choice are left alone so a retry stays queued.

    #>
    param([string]$GroupName)

    if (-not $GroupName) {
        # Refresh every ServiceGroup in the catalog.
        foreach ($property in $sync.configs.tweaks.PSObject.Properties) {
            if ($property.Value.Type -eq 'ServiceGroup') {
                Update-WinUtilServiceGroupState -GroupName $property.Name
            }
        }
        return
    }

    $group = $sync.configs.tweaks.$GroupName
    if (-not $group -or $null -eq $sync.ToggleStatusCache) { return }

    $states = @{}
    foreach ($key in @($group.Children)) {
        if ($null -ne $sync.PendingGroupSelections -and $sync.PendingGroupSelections.ContainsKey($key)) { continue }
        # Missing services read as not disabled; their checkboxes are hidden.
        $states[$key] = [bool](Get-WinUtilToggleStatus -ToggleSwitch $key -BypassCache)
        $sync.ToggleStatusCache[$key] = $states[$key]
    }
    if ($states.Count -eq 0) { return }

    Invoke-WPFUIThread -Parameters @{ States = $states; GroupName = $GroupName } -ScriptBlock {
        param($States, $GroupName)
        foreach ($key in @($States.Keys)) {
            $checkbox = $sync[$key]
            if ($null -eq $checkbox -or $checkbox.IsChecked -eq $States[$key]) { continue }
            # Updating keeps the change handler from staging a phantom operation.
            $checkbox.Tag.Updating = $true
            try { $checkbox.IsChecked = $States[$key] }
            finally { $checkbox.Tag.Updating = $false }
            Invoke-WPFSelectedCheckboxesUpdate -type $(if ($States[$key]) { 'Add' } else { 'Remove' }) -checkboxName $key
        }
        Update-WinUtilServiceGroupMaster -GroupName $GroupName
    }
}

function Get-WinUtilWindowsUpdateFiles {
    # Sysnative is required when a 32-bit PowerShell process runs on 64-bit Windows.
    $systemFolder = if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
        Join-Path $env:SystemRoot 'Sysnative'
    } else {
        Join-Path $env:SystemRoot 'System32'
    }

    foreach ($name in @('WaaSMedicSvc', 'wuaueng')) {
        [pscustomobject]@{
            Name = $name
            OriginalPath = Join-Path $systemFolder "$name.dll"
            RenamedPath = Join-Path $systemFolder "${name}_BAK.dll"
        }
    }
}

function Grant-WinUtilWindowsUpdateFileAccess {
    param([Parameter(Mandatory)][string]$Path)

    # Grant access only to the built-in Administrators group, not Everyone as in
    # the original BAT. Each file's original ACL is saved before this operation.
    $result = & takeown.exe /F $Path /A 2>&1
    if ($LASTEXITCODE -ne 0) { throw "takeown.exe failed for $Path ($LASTEXITCODE): $result" }
    $result = & icacls.exe $Path /grant '*S-1-5-32-544:F' 2>&1
    if ($LASTEXITCODE -ne 0) { throw "icacls.exe failed for $Path ($LASTEXITCODE): $result" }
}

function Restore-WinUtilWindowsUpdateFileSecurity {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$SecurityDescriptor
    )

    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    $acl.SetSecurityDescriptorSddlForm($SecurityDescriptor)
    Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
}

function Get-WinUtilWindowsUpdateFileSnapshot {
    $files = @()
    foreach ($file in @(Get-WinUtilWindowsUpdateFiles)) {
        $present = Test-Path -LiteralPath $file.OriginalPath
        $alreadyRenamed = Test-Path -LiteralPath $file.RenamedPath
        $descriptor = if ($present) { (Get-Acl -LiteralPath $file.OriginalPath -ErrorAction Stop).Sddl } else { $null }
        if ($present -and [string]::IsNullOrWhiteSpace($descriptor)) {
            throw "Could not back up the security descriptor of $($file.OriginalPath). No Windows files were changed."
        }
        $files += [pscustomobject]@{
            Name = $file.Name
            OriginalExisted = [bool]$present
            RenamedExisted = [bool]$alreadyRenamed
            SecurityDescriptor = $descriptor
        }
    }
    return $files
}

function Rename-WinUtilWindowsUpdateFiles {
    param([Parameter(Mandatory)]$Snapshot)

    $paths = @(Get-WinUtilWindowsUpdateFiles)
    foreach ($entry in @($Snapshot.Files)) {
        $file = $paths | Where-Object { $_.Name -eq $entry.Name } | Select-Object -First 1
        if ($null -eq $file) { Write-Warning "Unknown Windows Update file in snapshot: $($entry.Name)"; continue }
        if (-not $entry.OriginalExisted -or $entry.RenamedExisted) {
            Write-Warning "Skipping $($entry.Name).dll: the original file was missing or the _BAK file already existed before APBOptimizer."
            continue
        }
        if (-not (Test-Path -LiteralPath $file.OriginalPath)) {
            if (Test-Path -LiteralPath $file.RenamedPath) { continue } # Already renamed by an earlier attempt.
            Write-Warning "Neither original nor backup exists for $($entry.Name).dll."
            continue
        }
        if (Test-Path -LiteralPath $file.RenamedPath) {
            Write-Warning "Cannot rename $($entry.Name).dll because the _BAK name already exists."
            continue
        }

        try {
            Grant-WinUtilWindowsUpdateFileAccess -Path $file.OriginalPath
            Rename-Item -LiteralPath $file.OriginalPath -NewName (Split-Path $file.RenamedPath -Leaf) -ErrorAction Stop
            Write-WinUtilLog -Component 'WindowsUpdate' -Message "Renamed $($entry.Name).dll to $($entry.Name)_BAK.dll."
        } catch {
            Write-Warning "Could not rename protected Windows Update file $($entry.Name).dll: $($_.Exception.Message)"
        } finally {
            # Restore the original owner/DACL even if the rename failed midway.
            $actualPath = if (Test-Path -LiteralPath $file.RenamedPath) { $file.RenamedPath }
                          elseif (Test-Path -LiteralPath $file.OriginalPath) { $file.OriginalPath }
                          else { $null }
            if ($actualPath) {
                try { Restore-WinUtilWindowsUpdateFileSecurity -Path $actualPath -SecurityDescriptor $entry.SecurityDescriptor }
                catch { Write-Warning "Could not restore original permissions of $($entry.Name).dll: $($_.Exception.Message)" }
            }
        }
    }
}

function Restore-WinUtilWindowsUpdateFiles {
    param([Parameter(Mandatory)]$Snapshot)

    $failed = $false
    $paths = @(Get-WinUtilWindowsUpdateFiles)
    foreach ($entry in @($Snapshot.Files)) {
        # Do not claim or restore a DLL that was already renamed by another tool.
        if (-not $entry.OriginalExisted -or $entry.RenamedExisted) { continue }
        $file = $paths | Where-Object { $_.Name -eq $entry.Name } | Select-Object -First 1
        if ($null -eq $file) { $failed = $true; continue }
        $originalExists = Test-Path -LiteralPath $file.OriginalPath
        $renamedExists = Test-Path -LiteralPath $file.RenamedPath
        if ($originalExists -and -not $renamedExists) {
            # A prior restore may have renamed the file back but failed before
            # recovering its owner/ACL. Do not discard the snapshot prematurely.
            try {
                $currentSddl = (Get-Acl -LiteralPath $file.OriginalPath -ErrorAction Stop).Sddl
                if ($currentSddl -ne $entry.SecurityDescriptor) {
                    Grant-WinUtilWindowsUpdateFileAccess -Path $file.OriginalPath
                    Restore-WinUtilWindowsUpdateFileSecurity -Path $file.OriginalPath -SecurityDescriptor $entry.SecurityDescriptor
                }
            } catch {
                $failed = $true
                Write-Warning "Could not recover permissions of $($entry.Name).dll: $($_.Exception.Message)"
            }
            continue
        }
        if ($originalExists -or -not $renamedExists) {
            $failed = $true
            Write-Warning "Cannot restore $($entry.Name).dll: conflicting or missing original/_BAK files."
            continue
        }
        try {
            Grant-WinUtilWindowsUpdateFileAccess -Path $file.RenamedPath
            Rename-Item -LiteralPath $file.RenamedPath -NewName (Split-Path $file.OriginalPath -Leaf) -ErrorAction Stop
            Restore-WinUtilWindowsUpdateFileSecurity -Path $file.OriginalPath -SecurityDescriptor $entry.SecurityDescriptor
            Write-WinUtilLog -Component 'WindowsUpdate' -Message "Restored $($entry.Name).dll and its original permissions."
        } catch {
            $failed = $true
            Write-Warning "Could not restore $($entry.Name).dll: $($_.Exception.Message)"
        }
    }
    return (-not $failed)
}

function Write-WinUtilConsoleProgress {
    <#
        .SYNOPSIS
            Reports job progress on the console for runs that have no window

        .DESCRIPTION
            The progress bar is the only thing telling a user how far along a job is, so a
            headless run needs the same information in the only place it has.

            On a console the line is rewritten in place, because a package that reports every
            few hundred milliseconds would otherwise scroll a screenful for one install. When
            output is redirected there is no cursor to move, so each update is its own line and
            they are throttled hard instead.
    #>
    param(
        [string]$Status,
        [int]$Percent = -1
    )

    if ([string]::IsNullOrWhiteSpace($Status) -and $Percent -lt 0) {
        return
    }

    if ($null -eq $sync.ConsoleProgressState) {
        $sync.ConsoleProgressState = [hashtable]::Synchronized(@{
            LastText = ""
            LastWrite = [datetime]::MinValue
            LineLength = 0
            LineOpen = $false
        })
    }
    $state = $sync.ConsoleProgressState

    $text = if ([string]::IsNullOrWhiteSpace($Status)) { $state.LastText } else { $Status }
    if ([string]::IsNullOrWhiteSpace($text)) {
        return
    }

    $redirected = [Console]::IsOutputRedirected
    $throttleMs = if ($redirected) { 1000 } else { 150 }

    $now = Get-Date
    $sinceLast = ($now - $state.LastWrite).TotalMilliseconds

    # Redirected output cannot be rewritten in place, so every update is its own line and the
    # throttle holds even when the text changed. A job reporting per package would otherwise
    # scroll a screenful.
    if ($redirected) {
        if ($sinceLast -lt $throttleMs) { return }
    } elseif ($text -eq $state.LastText -and $sinceLast -lt $throttleMs) {
        return
    }

    $state.LastText = $text
    $state.LastWrite = $now

    $prefix = if ($Percent -ge 0) { "[{0,3}%] " -f $Percent } else { "[   =] " }
    $line = "$prefix$text"

    if ($redirected) {
        Write-Host $line -ForegroundColor DarkCyan
        return
    }

    # Pad to the previous length so a shorter line does not leave the tail of the longer one
    $padding = [Math]::Max(0, $state.LineLength - $line.Length)
    Write-Host ("`r$line" + (" " * $padding)) -NoNewline -ForegroundColor DarkCyan
    $state.LineLength = $line.Length
    $state.LineOpen = $true
}

function Complete-WinUtilConsoleProgress {
    <#
        .SYNOPSIS
            Ends the progress line so the next thing printed starts on its own

        .DESCRIPTION
            The line is rewritten in place and therefore left without a newline. Anything else
            reaching the console has to close it first, or it lands on top of the progress.
    #>

    $state = $sync.ConsoleProgressState
    if ($null -eq $state -or -not $state.LineOpen) {
        return
    }

    Write-Host ""
    $state.LineOpen = $false
    $state.LineLength = 0
    $state.LastText = ""
}

function Write-WinUtilErrorRecord {
    <#
        .SYNOPSIS
            Logs a failure with enough context to act on it

        .DESCRIPTION
            A bare "You cannot call a method on a null-valued expression." says nothing about
            where it came from. This records the message together with the exception type, the
            command and line that raised it, and the script stack, under a component name.

        .PARAMETER ErrorRecord
            The error to report, normally $_ from a catch block.

        .PARAMETER Component
            Which part of WinUtil was running, for example Install or UI.

        .PARAMETER Context
            What was being attempted, for example the button name or the package.
    #>
    param(
        [Parameter(Mandatory)]
        $ErrorRecord,

        [string]$Component = "WinUtil",

        [string]$Context,

        # The underlying failure was already logged and counted; retain this call's context and
        # stack as diagnostic detail without adding a second headline error.
        [switch]$DetailOnly
    )

    $headline = if ($Context) { "$Context : $($ErrorRecord.Exception.Message)" } else { $ErrorRecord.Exception.Message }
    Write-WinUtilLog -Level "ERROR" -Component $Component -Message $headline -Detail:$DetailOnly

    $invocation = $ErrorRecord.InvocationInfo
    if ($invocation) {
        $where = "$($invocation.ScriptName):$($invocation.ScriptLineNumber)"
        if ([string]::IsNullOrWhiteSpace($invocation.ScriptName)) {
            $where = "line $($invocation.ScriptLineNumber)"
        }
        Write-WinUtilLog -Level "ERROR" -Detail -Component $Component -Message "  at $where in $($invocation.MyCommand): $($invocation.Line.Trim())"
    }

    Write-WinUtilLog -Level "ERROR" -Detail -Component $Component -Message "  type $($ErrorRecord.Exception.GetType().FullName), category $($ErrorRecord.CategoryInfo.Category)"

    if ($ErrorRecord.ScriptStackTrace) {
        foreach ($frame in ($ErrorRecord.ScriptStackTrace -split "`r?`n")) {
            if (-not [string]::IsNullOrWhiteSpace($frame)) {
                Write-WinUtilLog -Level "ERROR" -Detail -Component $Component -Message "  $($frame.Trim())"
            }
        }
    }

    if (-not $DetailOnly) {
        Write-Host "$Component : $headline" -ForegroundColor Red
    }
}

function Write-WinUtilJobBanner {
    <#
        .SYNOPSIS
            Writes the boxed start, finish or failure line a job prints to the console

        .DESCRIPTION
            One place decides what a running operation looks like in the terminal, so every
            workflow announces itself the same way instead of hand-drawing its own box. Called
            by Start-WinUtilJob, not by job bodies.

        .PARAMETER Message
            The line to box, for example "Installing apps".

        .PARAMETER Level
            INFO for a normal banner, ERROR to colour it as a failure.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet("INFO", "ERROR")]
        [string]$Level = "INFO"
    )

    # A progress line is rewritten in place and left open, so the box would be drawn on top of it
    Complete-WinUtilConsoleProgress

    # Wrapped, because a failure listing several packages would otherwise draw a box wider
    # than the console
    $width = 76
    $words = $Message -split '\s+'
    $lines = [System.Collections.Generic.List[string]]::new()
    $current = ""
    foreach ($word in $words) {
        if ($current.Length -gt 0 -and ($current.Length + 1 + $word.Length) -gt $width) {
            $lines.Add($current)
            $current = $word
        } else {
            $current = if ($current.Length -eq 0) { $word } else { "$current $word" }
        }
    }
    if ($current.Length -gt 0) { $lines.Add($current) }

    $longest = ($lines | Measure-Object -Property Length -Maximum).Maximum
    $border = "=" * ($longest + 6)
    $colour = if ($Level -eq "ERROR") { "Red" } else { "Cyan" }

    Write-Host ""
    Write-Host $border -ForegroundColor $colour
    foreach ($line in $lines) {
        Write-Host ("-- {0}$(' ' * ($longest - $line.Length)) --" -f $line) -ForegroundColor $colour
    }
    Write-Host $border -ForegroundColor $colour
}

function Write-WinUtilLog {
    <#

    .SYNOPSIS
        Writes a timestamped WinUtil log entry to the active session log.

    .DESCRIPTION
        Called from the interface thread and from every job body. When Start-Transcript owns the
        active session log, entries go through the host so the transcript records them without a
        competing file write. Standalone callers use a named mutex to serialize direct appends.

    .PARAMETER Message
        The message to write.

    .PARAMETER Level
        The severity level for the log entry.

    .PARAMETER Component
        The WinUtil component producing the log entry.

    #>
    param (
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [ValidateSet("INFO", "WARN", "ERROR", "DEBUG")]
        [string]$Level = "INFO",

        [string]$Component = "WinUtil",

        # Continuation of an error already counted, such as a stack frame
        [switch]$Detail
    )

    # UI performance diagnostics are useful to developers but are too noisy for the release
    # transcript. Compile.ps1 stamps local builds so DEBUG output cannot leak into CI artifacts.
    if ($Level -eq "DEBUG" -and ($null -eq $sync -or -not $sync.IsLocalCompile)) {
        return
    }

    if ($Level -eq "ERROR" -and -not $Detail -and $null -ne $sync.LoggedErrors) {
        $null = $sync.LoggedErrors.Add("[$Component] $Message")
    }

    # Global scope is per runspace, so this counter only ever sees errors logged by the
    # runspace that owns it: a job worker reads its own, and a tweak on the UI thread reads the
    # UI thread's
    if ($Level -eq "ERROR" -and -not $Detail) {
        $global:WinUtilJobErrorCount++
    }

    try {
        $logPath = $null
        $transcriptPath = $null
        if ($null -ne $sync -and $sync.ContainsKey("logPath")) {
            $logPath = $sync.logPath
        }

        if ($null -ne $sync -and $sync.ContainsKey("transcriptPath")) {
            $transcriptPath = $sync.transcriptPath
        }

        if ([string]::IsNullOrWhiteSpace($logPath) -and -not [string]::IsNullOrWhiteSpace($transcriptPath)) {
            $logPath = $transcriptPath
        }

        if ([string]::IsNullOrWhiteSpace($logPath) -and $null -ne $sync -and $sync.ContainsKey("winutildir")) {
            $logDirectory = Join-Path $sync.winutildir "logs"
            $logPath = Join-Path $logDirectory "winutil_$(Get-Date -Format "yyyy-MM-dd_HH-mm-ss").log"
            $sync.logPath = $logPath
        }

        if ([string]::IsNullOrWhiteSpace($logPath) -and -not [string]::IsNullOrWhiteSpace($env:LocalAppData)) {
            if ([string]::IsNullOrWhiteSpace($script:WinUtilLogPath)) {
                $logDirectory = Join-Path (Join-Path $env:LocalAppData "winutil") "logs"
                $script:WinUtilLogPath = Join-Path $logDirectory "winutil_$(Get-Date -Format "yyyy-MM-dd_HH-mm-ss").log"
            }
            $logPath = $script:WinUtilLogPath
        }

        if ([string]::IsNullOrWhiteSpace($logPath)) {
            return
        }

        $logDirectory = Split-Path -Path $logPath -Parent
        if (-not (Test-Path $logDirectory)) {
            New-Item -Path $logDirectory -ItemType Directory -Force | Out-Null
        }

        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
        $line = "[$timestamp] [$Level] [$Component] $Message"

        if (-not [string]::IsNullOrWhiteSpace($transcriptPath) -and $logPath -eq $transcriptPath) {
            Write-Host $line
            return
        }

        $mutex = [System.Threading.Mutex]::new($false, "WinUtilSessionLog")
        $held = $false
        try {
            try {
                $held = $mutex.WaitOne(2000)
            } catch [System.Threading.AbandonedMutexException] {
                # A thread died holding the mutex; ownership transfers to us either way
                $held = $true
            }

            if (-not $held) {
                # Writing anyway is what interleaves lines, and the wait only times out when
                # contention is at its worst
                Write-Host $line
                return
            }

            Add-Content -Path $logPath -Value $line -Encoding UTF8 -ErrorAction Stop
        } catch [System.IO.IOException] {
            Write-Host $line
        } finally {
            if ($held) { $mutex.ReleaseMutex() }
            $mutex.Dispose()
        }
    } catch {
        Write-Warning "Unable to write WinUtil log entry: $($_.Exception.Message)"
    }
}

function Invoke-WinUtilAutoRun {
    <#

    .SYNOPSIS
        Runs every selected action to completion without a window

    .DESCRIPTION
        The headless path. Each action is the same job the button would start, run one at a time
        because the job layer allows one at a time, and waited on until the worker clears the
        busy flag.

        Returns a summary of what ran so the caller can decide the exit code. Nothing here
        touches the interface, so it behaves the same whether a window exists or not.

    .PARAMETER StopTimeoutSeconds
        How long a step that timed out is given to stop before the run gives up on the rest.

    .PARAMETER StepTimeoutSeconds
        How long a single action may take before the run gives up on it. Without a ceiling an
        installer waiting on something that will never arrive hangs the run for good.

    #>
    param(
        [int]$StepTimeoutSeconds = 3600,

        [int]$StopTimeoutSeconds = 30
    )

    # Bulk AppX removal requires an explicit UI confirmation. A saved/imported
    # configuration must not uninstall apps silently in a headless run.
    if (@($sync.selectedTweaks) -contains 'WPFTweaksDeBloat') {
        throw 'Bulk Microsoft Store app removal requires interactive confirmation in APBOptimizer. Remove WPFTweaksDeBloat from the headless configuration.'
    }

    $steps = @(
        [pscustomobject]@{ Name = 'Tweaks';  Count = @($sync.selectedTweaks).Count;  Action = { Invoke-WPFtweaksbutton } }
        [pscustomobject]@{ Name = 'Toggles'; Count = @($sync.selectedToggles).Count; Action = { Invoke-WPFToggleSelections } }
    )

    $planned = @($steps | Where-Object { $_.Count -gt 0 })
    if ($planned.Count -eq 0) {
        Write-WinUtilLog -Level "WARN" -Component "AutoRun" -Message "Nothing was selected, so there is nothing to do."
        return [pscustomobject]@{ Steps = @(); Failed = 0; TimedOut = 0; Errors = 0; Warnings = 0 }
    }

    Write-WinUtilLog -Component "AutoRun" -Message "Headless run starting: $(($planned | ForEach-Object { "$($_.Name) ($($_.Count))" }) -join ', ')"

    $results = New-Object System.Collections.ArrayList
    $runClock = [System.Diagnostics.Stopwatch]::StartNew()

    foreach ($step in $planned) {
        $errorsBefore = if ($sync.LoggedErrors) { $sync.LoggedErrors.Count } else { 0 }
        $sync.LastJobResult = $null
        $stepClock = [System.Diagnostics.Stopwatch]::StartNew()
        $timedOut = $false

        Write-WinUtilLog -Component "AutoRun" -Message "$($step.Name): starting $($step.Count) item(s)."

        try {
            & $step.Action
        } catch {
            Write-WinUtilErrorRecord -ErrorRecord $_ -Component "AutoRun" -Context "Starting $($step.Name)"
        }

        # The action starts a job and returns; the run is over when the worker clears the flag
        while ($sync.ActiveJob) {
            if ($stepClock.Elapsed.TotalSeconds -ge $StepTimeoutSeconds) {
                $timedOut = $true
                Write-WinUtilLog -Level "ERROR" -Component "AutoRun" -Message "$($step.Name) did not finish within $StepTimeoutSeconds seconds, moving on."
                break
            }
            Start-Sleep -Milliseconds 200
        }

        $stepClock.Stop()
        $newErrors = if ($sync.LoggedErrors) { $sync.LoggedErrors.Count - $errorsBefore } else { 0 }
        $newWarnings = if ($null -ne $sync.LastJobResult) { [int]$sync.LastJobResult.Warnings } else { 0 }

        $null = $results.Add([pscustomobject]@{
            Name = $step.Name
            Items = $step.Count
            Seconds = [int]$stepClock.Elapsed.TotalSeconds
            Errors = $newErrors
            Warnings = $newWarnings
            TimedOut = $timedOut
        })

        $outcome = if ($timedOut) { "timed out" } elseif ($newErrors -gt 0) { "finished with $newErrors error(s)" } elseif ($newWarnings -gt 0) { "finished with $newWarnings warning(s)" } else { "finished" }
        Write-WinUtilLog -Component "AutoRun" -Message "$($step.Name): $outcome after $([int]$stepClock.Elapsed.TotalSeconds)s."

        if ($timedOut) {
            # The worker is still on the pool. Clearing the slot on its own would let the next
            # step start beside it, so two runs would be changing the machine at once.
            Stop-WinUtilActiveWork -NoWait | Out-Null

            $stopDeadline = (Get-Date).AddSeconds($StopTimeoutSeconds)
            while ((Test-WinUtilActiveWorkRunning) -and (Get-Date) -lt $stopDeadline) {
                Start-Sleep -Milliseconds 200
            }

            # A job that never cleared the flag would make every later step refuse to start
            $null = Clear-WinUtilActiveJob

            if (Test-WinUtilActiveWorkRunning) {
                Write-WinUtilLog -Level "ERROR" -Component "AutoRun" -Message "$($step.Name) could not be stopped, so the remaining steps are abandoned rather than run beside it."
                break
            }
        }
    }

    $runClock.Stop()
    Write-WinUtilTimingSummary -Scope "AutoRun" -TotalMilliseconds $runClock.ElapsedMilliseconds

    return [pscustomobject]@{
        Steps = @($results)
        Failed = @($results | Where-Object { $_.Errors -gt 0 }).Count
        TimedOut = @($results | Where-Object { $_.TimedOut }).Count
        Errors = (@($results | Measure-Object -Property Errors -Sum).Sum)
        Warnings = (@($results | Measure-Object -Property Warnings -Sum).Sum)
    }
}

function Write-WinUtilAutoRunSummary {
    <#
        .SYNOPSIS
            Prints what a headless run did and returns the exit code it should end with
    #>
    param(
        [Parameter(Mandatory)]
        $Summary
    )

    Write-Host ""
    Write-Host "=== WinUtil headless run ===" -ForegroundColor Cyan

    foreach ($step in @($Summary.Steps)) {
        $state = if ($step.TimedOut) { "TIMED OUT" } elseif ($step.Errors -gt 0) { "$($step.Errors) error(s)" } elseif ($step.Warnings -gt 0) { "$($step.Warnings) warning(s)" } else { "ok" }
        $colour = if ($step.TimedOut -or $step.Errors -gt 0 -or $step.Warnings -gt 0) { "Yellow" } else { "Green" }
        Write-Host ("  {0,-14} {1,3} item(s)  {2,5}s  {3}" -f $step.Name, $step.Items, $step.Seconds, $state) -ForegroundColor $colour
    }

    if (@($Summary.Steps).Count -eq 0) {
        Write-Host "  nothing was selected" -ForegroundColor Yellow
        Write-Host ""
        return 2
    }

    if ($Summary.TimedOut -gt 0 -or $Summary.Failed -gt 0) {
        Write-Host ""
        Write-Host "Finished with problems. See $($sync.logPath)" -ForegroundColor Yellow
        Write-Host ""
        return 1
    }

    if ($Summary.Warnings -gt 0) {
        Write-Host ""
        Write-Host "Completed with warnings. See $($sync.logPath)" -ForegroundColor Yellow
        Write-Host ""
        return 0
    }

    Write-Host ""
    Write-Host "All steps completed. Log: $($sync.logPath)" -ForegroundColor Green
    Write-Host ""
    return 0
}

function Invoke-WPFButton {
    param([Parameter(Mandatory = $true)][string]$Button)

    if (-not $sync.ActiveJob) { Step-WinUtilJob -Hide }

    try {
        switch ($Button) {
            'WPFTab2BT'                { Invoke-WPFTab $Button }
            'WPFAdvancedTabBT'          { Invoke-WPFTab $Button }
            'WPFModeGuided'             { Select-WinUtilMode -Mode 'guided' }
            'WPFModeAdvanced'           { Select-WinUtilMode -Mode 'advanced' }
            'WPFGuidedYes'              { Submit-WinUtilGuidedAnswer -Answer $true }
            'WPFGuidedNo'               { Submit-WinUtilGuidedAnswer -Answer $false }
            'WPFGuidedBack'             { Step-WinUtilGuidedBack }
            'WPFGuidedSummaryBack'      { Show-WinUtilGuidedQuestion -Index (@(Get-WinUtilGuidedQuestions).Count - 1) }
            'WPFGuidedDoneAdvanced'     { Exit-WinUtilGuided }
            'WPFGuidedReview'           { Invoke-WinUtilGuidedReview }
            'WPFGuidedApply'            { Invoke-WinUtilGuidedApply }
            'WPFGuidedDoneHome'         { Show-WinUtilModeChooser }
            'WPFGuidedRestart'          { Restart-WinUtilComputer }
            'WPFGuidedCloseWindow'      { if ($sync.GuidedWindow) { $sync.GuidedWindow.Close() } }
            'WPFGuidedMinimizeWindow'   { if ($sync.GuidedWindow) { [Windows.SystemCommands]::MinimizeWindow($sync.GuidedWindow) } }
            'WPFDisableWindowsUpdate'   {
                $prompt = if ($sync.Language -eq 'es') {
                    'Modo agresivo: APBOptimizer intentará detener Windows Update y renombrar WaaSMedicSvc.dll y wuaueng.dll (archivos protegidos del sistema). Esto bloquea actualizaciones, incluidas las de seguridad, y puede afectar la reparación de Windows. La restauración podría requerir intervención manual. ¿Continuar?'
                } else { 'Aggressive mode: APBOptimizer will try to stop Windows Update and rename protected system files WaaSMedicSvc.dll and wuaueng.dll. This blocks updates, including security updates, and may affect Windows repair. Restoring may require manual recovery. Continue?' }
                if ((Show-WinUtilMessage -Title 'Windows Update' -Message $prompt -Button 'YesNo' -Icon 'Warning').ToString() -ne 'Yes') { return }
                Start-WinUtilJob -Name 'WindowsUpdate' -Description 'Disabling Windows Update' -ScriptBlock {
                    try { Set-WinUtilWindowsUpdate -Mode Disable }
                    finally { Update-WinUtilWindowsUpdateStatusUI }
                }
            }
            'WPFRestoreWindowsUpdate'   {
                $mode = 'Restore'
                if (Test-WinUtilWindowsUpdateRecoveryRequired) {
                    $message = if ($sync.Language -eq 'es') {
                        'Se detectaron DLL de Windows Update renombradas sin una copia original válida de APBOptimizer. La recuperación intentará devolver sus nombres usando los permisos del archivo _BAK, habilitar en modo Manual los servicios deshabilitados y retirar NoAutoUpdate=1. No puede garantizar que estos sean los ajustes originales. ¿Intentar la recuperación?'
                    } else {
                        'Windows Update DLLs were found renamed without a valid original APBOptimizer backup. Recovery will try to restore DLL names using their current _BAK file permissions, change disabled update services to Manual and remove NoAutoUpdate=1. Original settings cannot be guaranteed. Attempt recovery?'
                    }
                    if ((Show-WinUtilMessage -Title 'Windows Update Recovery' -Message $message -Button 'YesNo' -Icon 'Warning').ToString() -ne 'Yes') { return }
                    $mode = 'Recover'
                }
                Start-WinUtilJob -Name 'WindowsUpdate' -Description 'Restoring Windows Update' -Parameters @{ Mode = $mode } -ScriptBlock {
                    param($Mode)
                    try { Set-WinUtilWindowsUpdate -Mode $Mode }
                    finally { Update-WinUtilWindowsUpdateStatusUI }
                }
            }
            'WPFTweakHelpClose'         { $sync.WPFTweakHelpPopup.IsOpen = $false }
            'WPFTweakHelpDocs'          {
                $target = [string]$sync.WPFTweakHelpDocs.Tag
                $uri = $null
                if ([Uri]::TryCreate($target, [UriKind]::Absolute, [ref]$uri) -and $uri.Scheme -eq 'https') {
                    Start-Process -FilePath $uri.AbsoluteUri -ErrorAction Stop
                }
            }
            'WPFStandard'              { Invoke-WPFPresets 'Standard' -checkboxfilterpattern 'WPFTweak*' }
            'WPFMinimal'               { Invoke-WPFPresets 'Minimal' -checkboxfilterpattern 'WPFTweak*' }
            'WPFAdvanced'              { Invoke-WPFPresets 'Advanced' -checkboxfilterpattern 'WPFTweak*' }
            'WPFClearTweaksSelection'  { Invoke-WPFPresets -imported $true -checkboxfilterpattern 'WPFTweak*' }
            'WPFGetInstalledTweaks'    { Invoke-WPFGetInstalled -CheckBox 'tweaks' }
            'WPFTweaksbutton'          { Invoke-WPFtweaksbutton -IncludeToggles }
            'WPFUndoall'               { Invoke-WPFundoall }
            'WPFAddUltPerf'            {
                Start-WinUtilJob -Name 'Power' -Description 'Adding Ultimate Performance' -ScriptBlock {
                    Invoke-WPFUltimatePerformance -Enable
                }
            }
            'WPFRemoveUltPerf'         {
                Start-WinUtilJob -Name 'Power' -Description 'Restoring default power plans' -ScriptBlock {
                    Invoke-WPFUltimatePerformance
                }
            }
            'WPFCloseButton'           { $sync.Form.Close() }
            'WPFMinimizeButton'        { [Windows.SystemCommands]::MinimizeWindow($sync.Form) }
            'WPFMaximizeButton'        {
                if ($sync.Form.WindowState -eq [Windows.WindowState]::Normal) {
                    [Windows.SystemCommands]::MaximizeWindow($sync.Form)
                } else {
                    [Windows.SystemCommands]::RestoreWindow($sync.Form)
                }
            }
            # Settings, theme, font and search controls have their own event handlers.
            default { }
        }
    } catch {
        Write-WinUtilErrorRecord -ErrorRecord $_ -Component 'UI' -Context "Button '$Button'"
    }
}

function Invoke-WPFGetInstalled {
    param([string]$CheckBox)

    if ($CheckBox -ne 'tweaks') { return }

    Start-WinUtilJob -Name 'Detect applied tweaks' -Description 'Checking applied tweaks' -ScriptBlock {
        Step-WinUtilJob -Status 'Checking applied tweaks' -State 'Indeterminate'
        $found = @(Invoke-WinUtilCurrentSystem -CheckBox 'tweaks')
        Write-WinUtilLog -Component 'Tweaks' -Message "Detected $($found.Count) applied tweak(s)."
        Invoke-WPFUIThread -Parameters @{ Found = $found } -ScriptBlock {
            param($Found)
            foreach ($name in $Found) {
                if ($null -ne $sync.$name) {
                    $sync.$name.IsChecked = $true
                }
            }
        }
    }
}

function Invoke-WPFImpex {
    <#
    .SYNOPSIS
        Imports/exports ONLY APBOptimizer tweaks and toggles. This function
        never copies or invokes the original WinUtil URL.
    #>
    param(
        [ValidateSet('import', 'export')]
        [string]$type,
        [string]$Config = '',
        [switch]$Merge,
        [switch]$ThrowOnError
    )

    try {
        if ([string]::IsNullOrWhiteSpace($Config)) {
            Add-Type -AssemblyName System.Windows.Forms
            if ($type -eq 'export') {
                $dialog = [System.Windows.Forms.SaveFileDialog]::new()
            } else {
                $dialog = [System.Windows.Forms.OpenFileDialog]::new()
            }
            $dialog.Filter = 'JSON (*.json)|*.json'
            $dialog.DefaultExt = 'json'
            $dialog.InitialDirectory = [Environment]::GetFolderPath('Desktop')
            if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
            $Config = $dialog.FileName
        }

        if ($Config -match '^https?://') {
            throw 'APBOptimizer solamente acepta archivos locales para importar o exportar.'
        }

        if ($type -eq 'export') {
            $chosen = @($sync.selectedTweaks) + @($sync.selectedToggles) | Select-Object -Unique
            if ($chosen.Count -eq 0) {
                if ($sync.Form) {
                    Show-WinUtilMessage -Title 'APBOptimizer' -Message 'Primero selecciona algun tweak.' -Icon 'Warning' -Button 'OK' | Out-Null
                }
                return
            }
            ConvertTo-Json -InputObject @($chosen) -Depth 8 |
                Set-Content -LiteralPath $Config -Encoding UTF8
            return
        }

        $imported = Get-Content -LiteralPath $Config -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $imported = @($imported)
        if ($imported.Count -eq 0 -or $null -eq $imported[0]) {
            throw 'El JSON esta vacio. Se esperaba una lista de identificadores de tweaks.'
        }

        $valid = @()
        foreach ($item in $imported) {
            if ($item -isnot [string] -or $item -notmatch '^WPF(Tweaks|Toggle)') {
                throw "APBOptimizer no admite esta seleccion: $item"
            }
            $valid += $item
        }
        $parameters = @{}
        if (-not $Merge) { $parameters.Replace = $true }
        Update-WinUtilSelections -flatJson $valid @parameters
        if ($sync.Form) {
            $previousImportState = $sync.ImportInProgress
            try {
                $sync.ImportInProgress = $true
                Reset-WPFCheckBoxes -doToggles $true
            } finally {
                $sync.ImportInProgress = $previousImportState
            }
        }
    }
    catch {
        if ($ThrowOnError) { throw }
        if ($sync.Form) {
            Show-WinUtilMessage -Title 'APBOptimizer' -Message "No se pudo importar/exportar: $($_.Exception.Message)" -Icon 'Warning' -Button 'OK' | Out-Null
        } else {
            throw
        }
    }
}

function Invoke-WPFOOSU {
    Start-WinUtilJob -Name "OOSU" -Description "Downloading O&O ShutUp10++" -Parameters @{
        DownloadPath = Join-Path $sync.winutildir "ooshutup10.exe"
    } -ScriptBlock {
        param($DownloadPath)

        Write-WinUtilLog -Component "OOSU" -Message "Downloading O&O ShutUp10++."

        Save-WinUtilFile -Uri "https://dl5.oo-software.com/files/ooshutup10/OOSU10.exe" -DestinationPath $DownloadPath -ProgressCallback {
            param($percent)
            Step-WinUtilJob -Status "Downloading O&O ShutUp10++ ($percent%)" -Percent $percent
        }

        Step-WinUtilJob -Status "Launching O&O ShutUp10++" -Percent 100
        Start-Process -FilePath $DownloadPath
        Write-WinUtilLog -Component "OOSU" -Message "O&O ShutUp10++ launched."
    }
}

function Invoke-WPFPopup {
    param (
        [ValidateSet("Show", "Hide", "Toggle")]
        [string]$Action = "",

        [string[]]$Popups = @(),

        [ValidateScript({
            $invalid = $_.GetEnumerator() | Where-Object { $_.Value -notin @("Show", "Hide", "Toggle") }
            if ($invalid) {
                throw "Found invalid Popup-Action pair(s): " + ($invalid | ForEach-Object { "$($_.Key) = $($_.Value)" } -join "; ")
            }
            $true
        })]
        [hashtable]$PopupActionTable = @{}
    )

    if (-not $PopupActionTable.Count -and (-not $Action -or -not $Popups.Count)) {
        throw "Provide either 'PopupActionTable' or both 'Action' and 'Popups'."
    }

    if ($PopupActionTable.Count -and ($Action -or $Popups.Count)) {
        throw "Use 'PopupActionTable' on its own, or 'Action' with 'Popups'."
    }

    # Collect popups and actions
    $PopupsToProcess = if ($PopupActionTable.Count) {
        $PopupActionTable.GetEnumerator() | ForEach-Object { [PSCustomObject]@{ Name = "$($_.Key)Popup"; Action = $_.Value } }
    } else {
        $Popups | ForEach-Object { [PSCustomObject]@{ Name = "$_`Popup"; Action = $Action } }
    }

    $PopupsNotFound = @()

    # Apply actions
    foreach ($popupEntry in $PopupsToProcess) {
        $popupName = $popupEntry.Name

        if (-not $sync.$popupName) {
            $PopupsNotFound += $popupName
            continue
        }

        $sync.$popupName.IsOpen = switch ($popupEntry.Action) {
            "Show" { $true }
            "Hide" { $false }
            "Toggle" { -not $sync.$popupName.IsOpen }
        }
    }

    if ($PopupsNotFound.Count -gt 0) {
        throw "Could not find the following popups: $($PopupsNotFound -join ', ')"
    }
}

function Invoke-WPFPresets {
    <#

    .SYNOPSIS
        Sets the checkboxes in winutil to the given preset

    .PARAMETER preset
        The preset to set the checkboxes to

    .PARAMETER imported
        If the preset is imported from a file, defaults to false

    .PARAMETER checkboxfilterpattern
        The Pattern to use when filtering through CheckBoxes, defaults to "**"

    #>

    param (
        [Parameter(position=0)]
        [Array]$preset = $null,

        [Parameter(position=1)]
        [bool]$imported = $false,

        [Parameter(position=2)]
        [string]$checkboxfilterpattern = "**"
    )

    if ($imported -eq $true) {
        $CheckBoxesToCheck = $preset
    } else {
        $CheckBoxesToCheck = $sync.configs.preset.$preset
    }

    # clear out the filtered pattern so applying a preset replaces the current
    # state rather than merging with it
    switch ($checkboxfilterpattern) {
        "WPFTweak*" { $sync.selectedTweaks = [System.Collections.Generic.List[string]]::new() }
        "WPFToggle*" { $sync.selectedToggles = [System.Collections.Generic.List[string]]::new() }
        default {}
    }

    if ($preset) {
        Update-WinUtilSelections -flatJson $CheckBoxesToCheck
    }

    Reset-WPFCheckBoxes -doToggles $false -checkboxfilterpattern $checkboxfilterpattern
}

function Invoke-WPFRunspace {

    <#

    .SYNOPSIS
        Creates and invokes a runspace using the given scriptblock and argumentlist

    .PARAMETER ScriptBlock
        The scriptblock to invoke in the runspace

    .PARAMETER ArgumentList
        A list of arguments to pass to the runspace

    .PARAMETER ParameterList
        A list of named parameters that should be provided.
    .EXAMPLE
        Invoke-WPFRunspace `
            -ScriptBlock $sync.ScriptsInstallPrograms `
            -ArgumentList "Installadvancedip,Installbitwarden" `

        Invoke-WPFRunspace`
            -ScriptBlock $sync.ScriptsInstallPrograms `
            -ParameterList @(("PackagesToInstall", @("Installadvancedip,Installbitwarden")),("ChocoPreference", $true))
    #>

    [CmdletBinding()]
    [OutputType([System.IAsyncResult])]
    Param (
        $ScriptBlock,
        $ArgumentList,
        $ParameterList
    )

    $poolLock = Get-WinUtilRunspacePoolLock
    [System.Threading.Monitor]::Enter($poolLock)
    try {
        # The lifecycle lock keeps the final shutdown check, invocation start, and registration
        # atomic with pool closure. Otherwise shutdown can miss a newly started invocation.
        if ($sync.ShuttingDown) {
            Write-WinUtilLog -Level "WARN" -Component "UI" -Message "Refused to start background work, WinUtil is closing."
            return $null
        }

        Initialize-WinUtilRunspacePool | Out-Null

        # Create a PowerShell instance
        $powershell = [powershell]::Create()

        # Add Scriptblock and Arguments to runspace
        [void]$powershell.AddScript($ScriptBlock)
        [void]$powershell.AddArgument($ArgumentList)

        foreach ($parameter in $ParameterList) {
            # A single pair written as @(("Name", $value)) collapses to a two element array, and
            # indexing it then yields the first two characters of the name
            if ($parameter -is [string] -or $parameter.Count -ne 2) {
                throw "ParameterList takes name and value pairs. Received '$parameter'. A single pair needs a leading comma: -ParameterList (,('Name', `$value))"
            }
            [void]$powershell.AddParameter($parameter[0], $parameter[1])
        }

        $powershell.RunspacePool = $sync.runspace

        # Track before starting so no exception after BeginInvoke can make the caller release its
        # job token while work is actually running. Cleanup registration is best-effort and has a
        # background-thread fallback; it must never synchronously wait on a worker from the WPF
        # dispatcher because the worker's finalizer may be waiting to restore UI state.
        try {
            Register-WinUtilActiveShell -PowerShell $powershell
        } catch {
            $powershell.Dispose()
            throw
        }
        $handle = $null
        try {
            $handle = $powershell.BeginInvoke()
        } catch {
            $startError = $_
            $sync.ActiveShells.Remove($powershell)
            $powershell.Dispose()
            throw $startError
        }

        try {
            Register-WinUtilRunspaceCleanup -PowerShell $powershell -Handle $handle
        } catch {
            # The worker remains tracked and owns its job token. Treat it as scheduled so another
            # system-changing job cannot start beside it; later work/shutdown can reclaim the shell.
            Write-WinUtilLog -Level "WARN" -Component "UI" -Message "Could not register background cleanup: $($_.Exception.Message)"
        }

        return $handle
    } finally {
        [System.Threading.Monitor]::Exit($poolLock)
    }
}

function Invoke-WPFSelectedCheckboxesUpdate ($type, $checkboxName) {
    $listName = switch -Regex ($checkboxName) {
        '^WPFTweaks'  { 'selectedTweaks' }
        '^WPFToggle'  { 'selectedToggles' }
    }
    if (-not $listName) { return }
    if ($type -eq "Add") {
        if (-not $sync.$listName.Contains($checkboxName)) {
            $sync.$listName.Add($checkboxName)
        }
    } else {
        [void]$sync.$listName.Remove($checkboxName)
    }
}

function Invoke-WPFTab {
    param(
        [Parameter(Mandatory = $true)][string]$ClickedTab,
        [switch]$Yield
    )

    # Keep an explicit mapping. Upstream's positional six-tab navigation is gone.
    $tabName = switch ($ClickedTab) {
        'WPFTab2BT' { 'Tweaks' }
        'WPFAdvancedTabBT' { 'Advanced' }
        default { return }
    }
    $targetTab = switch ($tabName) {
        'Tweaks' { $sync.WPFTab2 }
        'Advanced' { $sync.WPFAdvancedTab }
    }
    if ($null -eq $targetTab) {
        throw "The $tabName tab is missing from the interface."
    }

    $sync.WPFTabNav.SelectedItem = $targetTab
    $sync.WPFTab2BT.IsChecked = ($tabName -eq 'Tweaks')
    $sync.WPFAdvancedTabBT.IsChecked = ($tabName -eq 'Advanced')
    $sync.currentTab = $tabName

    if ($tabName -eq 'Tweaks') {
        Initialize-WinUtilTabContent -TabName 'Tweaks' -Yield:$Yield
        $sync.WPFSearchBarContainer.Visibility = [System.Windows.Visibility]::Visible
        $sync.SearchBarClearButton.Visibility = if ($sync.SearchBar.Text) { 'Visible' } else { 'Collapsed' }
        Find-TweaksByNameOrDescription -SearchString $sync.SearchBar.Text
    } else {
        $sync.WPFSearchBarContainer.Visibility = [System.Windows.Visibility]::Collapsed
        $sync.SearchBarClearButton.Visibility = [System.Windows.Visibility]::Collapsed
        if ($tabName -eq 'Advanced') {
            Update-WinUtilWindowsUpdateStatusUI
        }
    }
}

function Invoke-WPFToggleSelections {
    <#

    .SYNOPSIS
        Applies every selected toggle

    .DESCRIPTION
        In the window a toggle applies itself the moment it is switched, so nothing ever had to
        apply a list of them. An imported configuration carries toggles the same way it carries
        tweaks, and without this they would be read and then ignored.

    #>

    $toggles = @($sync.selectedToggles)

    if ($toggles.Count -eq 0) {
        Show-WinUtilMessage -Message "No toggles are selected." -Title "WinUtil" -Button "OK" -Icon "Warning" | Out-Null
        return
    }

    Write-WinUtilLog -Component "Toggles" -Message "Toggles requested: $($toggles.Count) selected."

    Start-WinUtilJob -Name "Toggles" -Description "Applying toggles" -Parameters @{
        Toggles = $toggles
    } -ScriptBlock {
        param($Toggles)

        $total = [Math]::Max(@($Toggles).Count, 1)
        $completed = 0

        foreach ($toggle in $Toggles) {
            Step-WinUtilJob -Status "Applying $toggle ($($completed + 1)/$total)" -Percent ([int](($completed / $total) * 100))
            Measure-WinUtilStep -Scope "Toggles" -Name $toggle -ScriptBlock {
                Invoke-WinUtilTweaks $toggle
            }
            $completed++
            Step-WinUtilJob -Percent ([int](($completed / $total) * 100))
        }
    }
}

function Invoke-WPFtweaksbutton {
  <#

    .SYNOPSIS
        Invokes the functions associated with each group of checkboxes

  #>

  param([switch]$IncludeToggles)

  $Tweaks = @($sync.selectedTweaks)
  if ($IncludeToggles) {
    $Tweaks = @(@($Tweaks) + @($sync.selectedToggles) | Select-Object -Unique)
  }
  $TaskChanges = @()
  $GroupChanges = @()
  if ($sync.Form) {
    # Grouped services, drivers and tasks are diffed against their actual
    # state. Generic processing would duplicate them and miss queued restores.
    $Tweaks = @($Tweaks | Where-Object {
      $parent = $sync.configs.tweaks.$_.ParentGroup
      $parent -notin @('WPFServiceGroupDiagnostics', 'WPFServiceGroupUseless', 'WPFDriverGroupOptional', 'WPFTaskGroupTelemetry')
    })
    $TaskChanges = @(Get-WinUtilPendingTaskChanges)
    $GroupChanges = @(Get-WinUtilPendingGroupChanges)
  }
  $dnsProvider = if ($sync["WPFchangedns"].SelectedItem -and $sync["WPFchangedns"].SelectedItem.Tag) {
    [string]$sync["WPFchangedns"].SelectedItem.Tag
  } else {
    $sync["WPFchangedns"].Text
  }
  if (-not ($dnsProvider)) {
    $dnsProvider = "Default"
  }

  if ($Tweaks.count -eq 0 -and $TaskChanges.Count -eq 0 -and $GroupChanges.Count -eq 0 -and $dnsProvider -eq "Default") {
    $emptySelectionMessage = if ($sync.Language -eq 'es') { 'Selecciona los ajustes que quieres aplicar.' } else { 'Please check the tweaks you wish to perform.' }
    Show-WinUtilMessage -Message $emptySelectionMessage -Title "APBOptimizer" -Button "OK" -Icon "Warning"
    return
  }

  $driverDisables = @($GroupChanges | Where-Object {
    $_.Disable -and $sync.configs.tweaks.$($_.Key).ParentGroup -eq 'WPFDriverGroupOptional'
  })
  if ($driverDisables.Count -gt 0) {
    $driverNames = @($driverDisables | ForEach-Object { $sync.configs.tweaks.$($_.Key).driver.Name }) -join ', '
    $warning = if ($sync.Language -eq 'es') {
      "Vas a desactivar $($driverDisables.Count) driver(s) del kernel: $driverNames. Puede afectar DRM, red o funciones de energia. Se aplicara al reiniciar Windows. APBOptimizer guardara sus estados originales. ¿Continuar?"
    } else {
      "You are about to disable $($driverDisables.Count) kernel driver(s): $driverNames. This may affect DRM, networking or power features, and requires a reboot. APBOptimizer will back up their original states. Continue?"
    }
    $confirmation = Show-WinUtilMessage -Title 'APBOptimizer - Drivers' -Message $warning -Icon 'Warning' -Button 'YesNo'
    if ([string]$confirmation -ne 'Yes') { return }
  }

  if ($sync.Form -and $Tweaks -contains 'WPFTweaksDisableMemoryIntegrity') {
    $warning = if ($sync.Language -eq 'es') {
      'Desactivar Integridad de memoria (HVCI) reduce la seguridad del nucleo de Windows frente a malware y drivers maliciosos. No desactiva todo VBS. Necesitaras reiniciar para que el cambio tenga efecto. ¿Continuar?'
    } else {
      'Disabling Memory integrity (HVCI) reduces Windows kernel protection against malicious software and drivers. It does not disable all VBS. A reboot is required. Continue?'
    }
    if ([string](Show-WinUtilMessage -Title 'APBOptimizer - Memory Integrity' -Message $warning -Icon 'Warning' -Button 'YesNo') -ne 'Yes') { return }
  }

  if ($sync.Form -and $Tweaks -contains 'WPFTweaksDisablePowerThrottling') {
    $warning = if ($sync.Language -eq 'es') {
      'Desactivar Power Throttling en todo Windows puede aumentar el consumo, la temperatura y el uso de bateria. La mejora de rendimiento no esta garantizada. Se recomienda reiniciar. ¿Continuar?'
    } else {
      'Disabling Power Throttling system-wide may increase power draw, temperatures and battery drain. Performance gains are not guaranteed. Restarting is recommended. Continue?'
    }
    if ([string](Show-WinUtilMessage -Title 'APBOptimizer - Power Throttling' -Message $warning -Icon 'Warning' -Button 'YesNo') -ne 'Yes') { return }
  }

  if ($sync.Form -and $Tweaks -contains 'WPFTweaksDisableCPUMitigations') {
    $warning = if ($sync.Language -eq 'es') {
      'Desactivar las mitigaciones de CPU (Spectre/Meltdown) reduce la seguridad de Windows frente a ataques que pueden filtrar datos entre procesos. No garantiza mejores FPS. Es necesario reiniciar Windows para aplicar el cambio. APBOptimizer guardara los valores originales para Deshacer. ¿Continuar?'
    } else {
      'Disabling CPU mitigations (Spectre/Meltdown) weakens Windows protection against attacks that may leak data across processes. FPS gains are not guaranteed. Windows must be restarted. APBOptimizer will save the original settings for Undo. Continue?'
    }
    if ([string](Show-WinUtilMessage -Title 'APBOptimizer - CPU Mitigations' -Message $warning -Icon 'Warning' -Button 'YesNo') -ne 'Yes') { return }
  }

  if ($sync.Form -and $Tweaks -contains 'WPFTweaksDeBloat') {
    $warning = if ($sync.Language -eq 'es') {
      'ATENCION: se eliminaran numerosas aplicaciones de Microsoft Store de todos los usuarios y se quitara su aprovisionamiento para nuevas cuentas. La lista incluye Minecraft Bedrock, Gaming Services y aplicaciones instaladas por el usuario. Puedes perder datos de apps y juegos. NO existe restauracion automatica desde APBOptimizer; tendras que reinstalarlas manualmente. ¿Quieres continuar?'
    } else {
      'WARNING: This removes many Microsoft Store apps for all users and deprovisions them for new accounts. The list includes Minecraft Bedrock, Gaming Services and user-installed apps. App and game data may be lost. APBOptimizer CANNOT automatically undo this; you must reinstall affected apps manually. Continue?'
    }
    if ([string](Show-WinUtilMessage -Title 'APBOptimizer - MS Store Apps' -Message $warning -Icon 'Warning' -Button 'YesNo') -ne 'Yes') { return }
  }

  Write-WinUtilLog -Component "Tweaks" -Message "Tweaks requested: $(@($Tweaks).Count) tweak(s), $($TaskChanges.Count) scheduled-task change(s), $($GroupChanges.Count) service/driver change(s), DNS provider: $dnsProvider"

  Start-WinUtilJob -Name "Tweaks" -Description "Applying tweaks" -Parameters @{
    Tweaks = @($Tweaks)
    DnsProvider = $dnsProvider
    TaskChanges = @($TaskChanges)
    GroupChanges = @($GroupChanges)
  } -ScriptBlock {
    param($Tweaks, $DnsProvider, $TaskChanges, $GroupChanges)

    # The restore point has to be taken before anything else changes
    $restorePointTweak = "WPFTweaksRestorePoint"
    $tweaksToRun = @($Tweaks | Where-Object { $_ -ne $restorePointTweak })
    $totalSteps = [Math]::Max((@($Tweaks).Count + @($TaskChanges).Count + @($GroupChanges).Count), 1)
    $completedSteps = 0

    if ($Tweaks -contains $restorePointTweak) {
      Step-WinUtilJob -Status "Creating restore point" -Percent 0
      Write-WinUtilLog -Component "Tweaks" -Message "Creating restore point before applying selected tweaks."
      Measure-WinUtilStep -Scope "Tweaks" -Name $restorePointTweak -ScriptBlock {
        Invoke-WinUtilTweaks $restorePointTweak
      }
      $completedSteps = 1
    }

    if ($DnsProvider -ne "Default") {
      $dnsResult = Measure-WinUtilStep -Scope "Tweaks" -Name "Set DNS to $DnsProvider" -ScriptBlock {
        @(Set-WinUtilDNS -DNSProvider $DnsProvider)
      }

      # Carrying on after the DNS change failed leaves the machine half configured, so the run
      # ends here and the job layer reports it
      if (@($dnsResult)[-1] -ne $true) {
        throw "The DNS change to $DnsProvider failed, so the remaining tweaks were not applied."
      }
    }

    foreach ($tweak in $tweaksToRun) {
      Step-WinUtilJob -Status "Applying $tweak ($($completedSteps + 1)/$totalSteps)" -Percent ([int](($completedSteps / $totalSteps) * 100))
      Measure-WinUtilStep -Scope "Tweaks" -Name $tweak -ScriptBlock {
        Invoke-WinUtilTweaks $tweak
      }
      $completedSteps++
      Step-WinUtilJob -Percent ([int](($completedSteps / $totalSteps) * 100))
    }
    foreach ($taskChange in @($TaskChanges)) {
      $key = [string]$taskChange.Key
      Step-WinUtilJob -Status "Applying scheduled task $key ($($completedSteps + 1)/$totalSteps)" -Percent ([int](($completedSteps / $totalSteps) * 100))
      Measure-WinUtilStep -Scope "Tweaks" -Name $key -ScriptBlock {
        Invoke-WinUtilPendingTaskChanges -Changes @($taskChange)
      }
      $completedSteps++
      Step-WinUtilJob -Percent ([int](($completedSteps / $totalSteps) * 100))
    }
    foreach ($groupChange in @($GroupChanges)) {
      $key = [string]$groupChange.Key
      Step-WinUtilJob -Status "Applying service/driver $key ($($completedSteps + 1)/$totalSteps)" -Percent ([int](($completedSteps / $totalSteps) * 100))
      Measure-WinUtilStep -Scope "Tweaks" -Name $key -ScriptBlock {
        Invoke-WinUtilPendingGroupChanges -Changes @($groupChange)
      }
      $completedSteps++
      Step-WinUtilJob -Percent ([int](($completedSteps / $totalSteps) * 100))
    }
    if (Test-WinUtilUIAlive) {
      Update-WinUtilServiceGroupState
    }
  }
}

function Invoke-WPFUIElements {
    <#
    .SYNOPSIS
        Adds UI elements to a specified Grid in the WinUtil GUI based on a JSON configuration.
    .PARAMETER configVariable
        The variable/link containing the JSON configuration.
    .PARAMETER targetGridName
        The name of the grid to which the UI elements should be added.
    .PARAMETER columncount
        The number of columns to be used in the Grid. If not provided, a default value is used based on the panel.
    .EXAMPLE
        Invoke-WPFUIElements -configVariable $sync.configs.tweaks -targetGridName "tweakspanel" -columncount 2
    .NOTES
        Future me/contributor: If possible, please wrap this into a runspace to make it load all panels at the same time.
    #>

    param(
        [Parameter(Mandatory, Position = 0)]
        [PSCustomObject]$configVariable,

        [Parameter(Mandatory, Position = 1)]
        [string]$targetGridName,

        [Parameter(Mandatory, Position = 2)]
        [int]$columncount,

        # Let the interface answer between batches of entries. Only for content nobody is
        # waiting on: a user who just clicked the tab is better served by finishing at once.
        [switch]$Yield
    )

    $window = $sync.form

    $borderstyle = $window.FindResource("BorderStyle")
    $HoverTextBlockStyle = $window.FindResource("HoverTextBlockStyle")
    $ColorfulToggleSwitchStyle = $window.FindResource("ColorfulToggleSwitchStyle")
    $ToggleButtonStyle = $window.FindResource("ToggleButtonStyle")

    if (!$borderstyle -or !$HoverTextBlockStyle -or !$ColorfulToggleSwitchStyle) {
        throw "Failed to retrieve Styles using 'FindResource' from main window element."
    }

    $targetGrid = $window.FindName($targetGridName)

    if (!$targetGrid) {
        throw "Failed to retrieve Target Grid by name, provided name: $targetGrid"
    }

    # Clear existing ColumnDefinitions and Children
    $targetGrid.ColumnDefinitions.Clear() | Out-Null
    $targetGrid.Children.Clear() | Out-Null

    # Add ColumnDefinitions to the target Grid
    for ($i = 0; $i -lt $columncount; $i++) {
        $colDef = New-Object Windows.Controls.ColumnDefinition
        $colDef.Width = New-Object System.Windows.GridLength([double]1, [System.Windows.GridUnitType]::Star)
        $targetGrid.ColumnDefinitions.Add($colDef) | Out-Null
    }

    # Convert PSCustomObject to Hashtable
    $configHashtable = @{}
    $configVariable.PSObject.Properties.Name | ForEach-Object {
        $configHashtable[$_] = $configVariable.$_
    }

    $radioButtonGroups = @{}

    $organizedData = @{}
    # Iterate through JSON data and organize by panel and category
    foreach ($entry in $configHashtable.Keys) {
        $entryInfo = $configHashtable[$entry]
        $entryLocale = Get-WinUtilLocalizedEntry -Key $entry
        # Children are rendered inside the group's drop-down, never as separate
        # rows at the category level.
        if ($entryInfo.ParentGroup) { continue }

        # Create an object for the application
        $entryObject = [PSCustomObject]@{
            Name        = $entry
            Category    = $entryInfo.Category
            Content     = if ($entryLocale -and $null -ne $entryLocale.Content) { $entryLocale.Content } else { $entryInfo.Content }
            Panel       = if ($entryInfo.Panel) { $entryInfo.Panel } else { "0" }
            Link        = $entryInfo.link
            Description = if ($entryLocale -and $null -ne $entryLocale.Description) { $entryLocale.Description } else { $entryInfo.description }
            Type        = $entryInfo.type
            ComboItems  = $entryInfo.ComboItems
            LocalizedComboItems = if ($entryLocale) { $entryLocale.ComboItems } else { $null }
            ComboDescriptions = $entryInfo.ComboDescriptions
            LocalizedComboDescriptions = if ($entryLocale) { $entryLocale.ComboDescriptions } else { $null }
            Registry    = $entryInfo.registry
            Checked     = $entryInfo.Checked
            ButtonWidth = $entryInfo.ButtonWidth
            GroupName   = $entryInfo.GroupName  # Added for RadioButton groupings
            Children    = $entryInfo.Children
        }

        if (-not $organizedData.ContainsKey($entryObject.Panel)) {
            $organizedData[$entryObject.Panel] = @{}
        }

        if (-not $organizedData[$entryObject.Panel].ContainsKey($entryObject.Category)) {
            $organizedData[$entryObject.Panel][$entryObject.Category] = @()
        }

        # Store application data in an array under the category
        $organizedData[$entryObject.Panel][$entryObject.Category] += $entryObject

    }

    # Initialize panel count
    $panelcount = 0

    # Iterate through 'organizedData' by panel, category, and application
    $yieldClock = [System.Diagnostics.Stopwatch]::StartNew()
    foreach ($panelKey in ($organizedData.Keys | Sort-Object)) {
        # Create a Border for each column
        $border = New-Object Windows.Controls.Border
        $border.VerticalAlignment = "Stretch"
        [System.Windows.Controls.Grid]::SetColumn($border, $panelcount)
        $border.style = $borderstyle
        $targetGrid.Children.Add($border) | Out-Null

        # Use a DockPanel to contain the content
        $dockPanelContainer = New-Object Windows.Controls.DockPanel
        $border.Child = $dockPanelContainer

        # Create a StackPanel for application content controls
        $stackPanelContainer = New-Object Windows.Controls.StackPanel
        $stackPanelContainer.HorizontalAlignment = 'Stretch'
        $stackPanelContainer.VerticalAlignment = 'Stretch'

        # Check if the target grid (or any ancestor) is already inside a ScrollViewer
        $hasOuterScrollViewer = $false
        $currentElement = $targetGrid
        while ($null -ne $currentElement) {
            if ($currentElement -is [System.Windows.Controls.ScrollViewer] -or $currentElement.GetType().Name -eq "ScrollViewer") {
                $hasOuterScrollViewer = $true
                break
            }
            $currentElement = $currentElement.Parent
        }

        if ($hasOuterScrollViewer) {
            # Add StackPanel directly to DockPanel without nesting a ScrollViewer
            [Windows.Controls.DockPanel]::SetDock($stackPanelContainer, [Windows.Controls.Dock]::Bottom)
            $dockPanelContainer.Children.Add($stackPanelContainer) | Out-Null
        }
        else {
            # Create a ScrollViewer for targets that do not already have an outer ScrollViewer
            $scrollViewer = New-Object Windows.Controls.ScrollViewer
            $scrollViewer.VerticalScrollBarVisibility = "Auto"
            $scrollViewer.HorizontalScrollBarVisibility = "Disabled"
            $scrollViewer.HorizontalAlignment = 'Stretch'
            $scrollViewer.VerticalAlignment = 'Stretch'
            $scrollViewer.Content = $stackPanelContainer

            [Windows.Controls.DockPanel]::SetDock($scrollViewer, [Windows.Controls.Dock]::Bottom)
            $dockPanelContainer.Children.Add($scrollViewer) | Out-Null
        }
        $panelcount++

        # Now proceed with adding category labels and entries to $stackPanelContainer
        foreach ($category in ($organizedData[$panelKey].Keys | Sort-Object)) {

            $label = New-Object Windows.Controls.Label
            $categoryCleanName = $category -replace ".*__", ""
            $label.Content = Get-WinUtilLocalizedCategory -Category $categoryCleanName
            $label.Focusable = $true
            $label.IsTabStop = $true
            [System.Windows.Automation.AutomationProperties]::SetName($label, $categoryCleanName)
            $label.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "HeaderFontSize")
            $label.SetResourceReference([Windows.Controls.Control]::FontFamilyProperty, "HeaderFontFamily")
            $label.UseLayoutRounding = $true
            $stackPanelContainer.Children.Add($label) | Out-Null
            $sync[$category] = $label

            # Sort entries by type (checkboxes first, then buttons, then comboboxes, notes last) and then alphabetically by Content
            $entries = $organizedData[$panelKey][$category] | Sort-Object @{Expression = {
                switch ($_.Type) {
                    'Button' { 1 }
                    'Combobox' { 2 }
                    'Note' { 3 }
                    default { 0 }
                }
            }}, Content
            foreach ($entryInfo in $entries) {

                # Constructing a panel's worth of controls in one go holds the interface for
                # hundreds of milliseconds. Draining the queue on a deadline rather than every
                # nth entry keeps the wait bounded whatever the entries cost to build.
                if ($Yield -and $yieldClock.ElapsedMilliseconds -ge 25 -and (Test-WinUtilUIAlive)) {
                    $yieldClock.Restart()
                    $frame = New-Object Windows.Threading.DispatcherFrame
                    $null = $sync.Form.Dispatcher.BeginInvoke(
                        [Windows.Threading.DispatcherPriority]::Background,
                        [Windows.Threading.DispatcherOperationCallback]{
                            param($dispatcherFrame)
                            $dispatcherFrame.Continue = $false
                            return $null
                        },
                        $frame)
                    [Windows.Threading.Dispatcher]::PushFrame($frame)
                }

                # Create the UI elements based on the entry type
                switch ($entryInfo.Type) {
                    { $_ -in @('ServiceGroup', 'DriverGroup', 'TaskGroup') } {
                        $isDriverGroup = ($entryInfo.Type -eq 'DriverGroup')
                        $isTaskGroup = ($entryInfo.Type -eq 'TaskGroup')
                        # Same small checkboxes as ordinary Advanced Tweaks. A frameless
                        # triangle at the left only expands/collapses the indented list.
                        $groupWrapper = New-Object Windows.Controls.StackPanel
                        # Populate search terms after checking installed services,
                        # so searching for an unavailable service does not show it.
                        # Ordinary entries use only the checkbox's own margins.
                        # Extra wrapper spacing made this row noticeably taller.
                        $groupWrapper.Margin = '0'
                        # A shared grid lets the arrow sit immediately before the
                        # checkmark without shifting that checkmark off the column
                        # used by the other Advanced Tweaks.
                        $header = New-Object Windows.Controls.Grid
                        $header.VerticalAlignment = 'Center'

                        $expand = New-Object Windows.Controls.Button
                        $expand.Name = $entryInfo.Name + 'Expander'
                        $expand.Content = 'Collapsed'
                        $expand.Style = $window.FindResource('ServiceGroupExpanderStyle')
                        $expand.HorizontalAlignment = 'Left'
                        $expand.VerticalAlignment = 'Center'
                        $expand.Margin = '19,-1,0,3'
                        $expand.ToolTip = if ($isTaskGroup) { 'Expand or collapse the scheduled task list' } elseif ($isDriverGroup) { 'Expand or collapse the driver list' } else { 'Expand or collapse the service list' }
                        # The checkbox's outer transparent area overlaps the arrow;
                        # keep the arrow above it so both hit targets work.
                        [Windows.Controls.Panel]::SetZIndex($expand, 1)
                        $header.Children.Add($expand) | Out-Null

                        $master = New-Object Windows.Controls.CheckBox
                        $master.Name = $entryInfo.Name
                        $master.Content = $entryInfo.Content
                        $master.HorizontalAlignment = 'Left'
                        $master.VerticalAlignment = 'Center'
                        # Match the visible square's baseline and the 18px height
                        # of normal Advanced rows without adding bottom padding.
                        $master.Margin = '15,-1,0,1'
                        $master.UseLayoutRounding = $true
                        $master.ToolTip = if ($isTaskGroup) {
                            "Disable or restore all available optional scheduled tasks. $($entryInfo.Description)"
                        } elseif ($isDriverGroup) {
                            "Select eligible drivers; changes run only when you click Apply Tweaks. Review each driver's impact and reboot. $($entryInfo.Description)"
                        } else { "Select services to disable or restore when you click Apply Tweaks. $($entryInfo.Description)" }
                        $master.Tag = @{ Children = [string[]]@($entryInfo.Children); Updating = $false; IsDriverGroup = $isDriverGroup; IsTaskGroup = $isTaskGroup; NoManageableDrivers = $false; AllAlreadyDisabled = $false; UnavailableMessage = '' }
                        [System.Windows.Automation.AutomationProperties]::SetName($master, $entryInfo.Content)
                        $header.Children.Add($master) | Out-Null

                        $groupWrapper.Children.Add($header) | Out-Null

                        $childPanel = New-Object Windows.Controls.StackPanel
                        $childPanel.Margin = '30,1,0,2'
                        $childPanel.Visibility = [Windows.Visibility]::Collapsed
                        $groupWrapper.Children.Add($childPanel) | Out-Null
                        $stackPanelContainer.Children.Add($groupWrapper) | Out-Null
                        $sync[$entryInfo.Name] = $master
                        $sync[$expand.Name] = $expand
                        $sync[$entryInfo.Name + 'Children'] = $childPanel

                        $expand.Tag = $childPanel
                        $expand.Add_Click({
                            $children = $this.Tag
                            $isOpening = ($children.Visibility -ne [Windows.Visibility]::Visible)
                            $children.Visibility = if ($isOpening) { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed }
                            $this.Content = if ($isOpening) { 'Expanded' } else { 'Collapsed' }
                        })

                        # One scheduler read per TaskGroup render. The previous
                        # per-child status + info checks enumerated every Windows
                        # task twenty times and stalled the UI for seconds.
                        $taskSnapshot = @()
                        $taskBackup = $null
                        $taskReadError = $null
                        if ($isTaskGroup) {
                            try {
                                $taskSnapshot = @(Get-ScheduledTask -ErrorAction Stop)
                                $taskBackup = Get-WinUtilTelemetryTaskBackup
                            } catch {
                                $taskReadError = $_.Exception.Message
                            }
                            if ($null -eq $sync.ToggleStatusCache) {
                                $sync.ToggleStatusCache = @{}
                            }
                        }
                        $driverMissingNames = [System.Collections.Generic.List[string]]::new()
                        $driverAlreadyDisabledNames = [System.Collections.Generic.List[string]]::new()
                        $driverProtectedNames = [System.Collections.Generic.List[string]]::new()
                        foreach ($childKey in @($entryInfo.Children)) {
                            $childConfig = $configHashtable[$childKey]
                            $childLocale = Get-WinUtilLocalizedEntry -Key $childKey
                            if ($null -eq $childConfig -or $childConfig.Type -ne 'Toggle' -or $childConfig.ParentGroup -ne $entryInfo.Name -or
                                ($isDriverGroup -and -not $childConfig.driver.Name) -or ($isTaskGroup -and -not $childConfig.scheduledTask.Name)) {
                                throw "Invalid group child '$childKey' in '$($entryInfo.Name)'."
                            }
                            $childToggle = New-Object Windows.Controls.CheckBox
                            $childToggle.Name = $childKey
                            $childToggle.Content = if ($childLocale -and $childLocale.Content) { $childLocale.Content } else { $childConfig.Content }
                            $childToggle.HorizontalAlignment = 'Left'
                            $childToggle.VerticalAlignment = 'Center'
                            $childToggle.Margin = '0,1,0,1'
                            $childToggle.UseLayoutRounding = $true
                            $childToggle.Tag = @{ Group = $entryInfo.Name; Updating = $false; IsDriverGroup = $isDriverGroup; IsTaskGroup = $isTaskGroup }
                            $childInfo = if ($childLocale -and $childLocale.Description) { $childLocale.Description } else { $childConfig.Description }
                            $childToggle.ToolTip = if ($isTaskGroup) { $childInfo } elseif ($isDriverGroup) { "$childInfo $(if ($sync.Language -eq 'es') { 'Pulsa Aplicar ajustes para realizar cambios. Se requiere reiniciar.' } else { 'Click Apply Tweaks to make changes. A reboot is required.' })" } else {
                                if ($sync.Language -eq 'es') { "$childInfo Los cambios se realizan al pulsar Aplicar ajustes." } else { "$childInfo Changes run when you click Apply Tweaks." }
                            }
                            [System.Windows.Automation.AutomationProperties]::SetName($childToggle, $childConfig.Content)
                            $childPanel.Children.Add($childToggle) | Out-Null
                            $sync[$childKey] = $childToggle

                            if ($isTaskGroup) {
                                if ($taskReadError) {
                                    $childToggle.IsEnabled = $false
                                    $childToggle.ToolTip = "$($childToggle.ToolTip) $taskReadError"
                                } else {
                                    try {
                                        $taskInfo = Get-WinUtilTelemetryTaskInfo -Name $childConfig.scheduledTask.Name -TaskSnapshot $taskSnapshot -Backup $taskBackup
                                        $sync.ToggleStatusCache[$childKey] = [bool]$taskInfo.Disabled
                                        $childToggle.IsChecked = [bool]$taskInfo.Disabled
                                        if ($null -ne $sync.PendingTaskSelections -and
                                            $sync.PendingTaskSelections.ContainsKey($childKey)) {
                                            $childToggle.IsChecked = [bool]$sync.PendingTaskSelections[$childKey]
                                        }
                                        if (-not $taskInfo.Present) {
                                            $childToggle.IsEnabled = $false
                                            $childToggle.Visibility = [Windows.Visibility]::Collapsed
                                        } elseif (-not $taskInfo.CanChange) {
                                            $childToggle.IsEnabled = $false
                                            $childToggle.ToolTip = "$($childToggle.ToolTip) $($taskInfo.Reason)"
                                        }
                                    } catch {
                                        $childToggle.IsEnabled = $false
                                        $childToggle.ToolTip = "$($childToggle.ToolTip) $($_.Exception.Message)"
                                    }
                                }
                            } else {
                                $childToggle.IsChecked = Get-WinUtilToggleStatus $childKey
                                if ($null -eq $sync.ToggleStatusCache) {
                                    $sync.ToggleStatusCache = @{}
                                }
                                # Store the real initial state once. Subsequent
                                # checkbox events only compare with this cache.
                                $sync.ToggleStatusCache[$childKey] = [bool]$childToggle.IsChecked
                                if ($null -ne $sync.PendingGroupSelections -and
                                    $sync.PendingGroupSelections.ContainsKey($childKey)) {
                                    $childToggle.IsChecked = [bool]$sync.PendingGroupSelections[$childKey]
                                }
                            }
                            if ($isDriverGroup) {
                                $driverInfo = Get-WinUtilOptionalDriverInfo -Name $childConfig.driver.Name
                                if (-not $driverInfo.Present) {
                                    $driverMissingNames.Add($childConfig.driver.Name)
                                    $childToggle.IsEnabled = $false
                                    $childToggle.Visibility = [Windows.Visibility]::Collapsed
                                } elseif (-not $driverInfo.CanChange) {
                                    $reason = $driverInfo.Reason
                                    if ($driverInfo.Disabled -and -not $driverInfo.Managed) {
                                        $driverAlreadyDisabledNames.Add($childConfig.driver.Name)
                                        if ($sync.Language -eq 'es') { $reason = 'Ya estaba desactivado fuera de APBOptimizer; no hay un modo de inicio original guardado para reactivarlo.' }
                                    } else {
                                        $driverProtectedNames.Add($childConfig.driver.Name)
                                    }
                                    $childToggle.IsEnabled = $false
                                    $childToggle.ToolTip = "$($childToggle.ToolTip) $reason"
                                }
                            } elseif (-not $isTaskGroup -and -not (Get-Service -Name $childConfig.service[0].Name -ErrorAction SilentlyContinue)) {
                                $childToggle.IsEnabled = $false
                                # Missing services do not occupy space in the list.
                                $childToggle.Visibility = [Windows.Visibility]::Collapsed
                            }

                            # All three advanced groups only stage selections.
                            # The main Apply Tweaks job changes the OS later.
                            $onServiceChange = {
                                [System.Object]$senderControl = $args[0]
                                if ($senderControl.Tag.Updating) { return }
                                $requested = ($senderControl.IsChecked -eq $true)
                                if (-not $sync.ImportInProgress) {
                                    $pendingName = if ($senderControl.Tag.IsTaskGroup) {
                                        'PendingTaskSelections'
                                    } else {
                                        'PendingGroupSelections'
                                    }
                                    if ($null -eq $sync[$pendingName]) {
                                        $sync[$pendingName] = [hashtable]::Synchronized(@{})
                                    }
                                    try {
                                        # A cached baseline avoids synchronous
                                        # registry/service/scheduler reads per click.
                                        $actual = Get-WinUtilToggleStatus $senderControl.Name
                                        if ($requested -eq $actual) {
                                            $sync[$pendingName].Remove($senderControl.Name)
                                        } else {
                                            $sync[$pendingName][$senderControl.Name] = $requested
                                        }
                                    } catch {
                                        $senderControl.Tag.Updating = $true
                                        try { $senderControl.IsChecked = -not $requested }
                                        finally { $senderControl.Tag.Updating = $false }
                                        Show-WinUtilMessage -Title 'APBOptimizer' -Message "Could not stage $($senderControl.Name): $($_.Exception.Message)" -Icon 'Warning' -Button 'OK' | Out-Null
                                        return
                                    }
                                }
                                Invoke-WPFSelectedCheckboxesUpdate -type $(if ($senderControl.IsChecked) { 'Add' } else { 'Remove' }) -checkboxName $senderControl.Name
                                Update-WinUtilServiceGroupMaster -GroupName $senderControl.Tag.Group
                            }
                            $childToggle.Add_Checked($onServiceChange)
                            $childToggle.Add_Unchecked($onServiceChange)
                        }

                        $installedSearchTerms = @($entryInfo.Children | Where-Object {
                            $sync[$_] -and $sync[$_].Visibility -eq [Windows.Visibility]::Visible
                        } | ForEach-Object {
                            $childDefinition = $configHashtable[$_]
                            $systemName = if ($childDefinition.driver) { $childDefinition.driver.Name } elseif ($childDefinition.scheduledTask) { $childDefinition.scheduledTask.Name } else { $childDefinition.service[0].Name }
                            "$_ $($childDefinition.Content) $systemName"
                        }) -join ' '
                        $groupWrapper.Tag = "$($entryInfo.Content) $($entryInfo.Description) $installedSearchTerms"

                        if ($isDriverGroup) {
                            $manageable = @($entryInfo.Children | Where-Object {
                                $sync[$_] -and $sync[$_].IsEnabled -and
                                $sync[$_].Visibility -eq [Windows.Visibility]::Visible
                            }).Count
                            if ($manageable -eq 0) {
                                $isSpanish = ($sync.Language -eq 'es')
                                # One line per non-empty category, naming the drivers.
                                $lines = @(if ($isSpanish) { 'No hay nada que aplicar en este grupo.' } else { 'There is nothing to apply in this group.' })
                                foreach ($category in @(
                                    @{ Names = $driverAlreadyDisabledNames; Label = $(if ($isSpanish) { 'Ya desactivados' } else { 'Already disabled' }) },
                                    @{ Names = $driverMissingNames; Label = $(if ($isSpanish) { 'No instalados' } else { 'Not installed' }) },
                                    @{ Names = $driverProtectedNames; Label = $(if ($isSpanish) { 'Protegidos' } else { 'Protected' }) }
                                )) {
                                    if ($category.Names.Count -gt 0) {
                                        $lines += "$($category.Label) ($($category.Names.Count)): $($category.Names -join ', ')."
                                    }
                                }
                                if ($driverAlreadyDisabledNames.Count -gt 0) {
                                    $lines += if ($isSpanish) {
                                        "`nLos desactivó otra herramienta, una versión anterior de APBOptimizer o un cambio manual, así que no hay un modo de inicio original guardado. APBOptimizer no lo adivina y no puede reactivarlos. Para reactivar uno, usa un punto de restauración anterior al cambio o reinstala el programa que lo instaló."
                                    } else {
                                        "`nThey were disabled by another tool, an older APBOptimizer version or by hand, so no original startup mode was saved. APBOptimizer will not guess it and cannot re-enable them. To re-enable one, use a restore point from before the change or reinstall the program that installed it."
                                    }
                                }
                                $explanation = Convert-WinUtilTextEncoding -Text ($lines -join "`n")
                                $allAlreadyDisabled = ($driverAlreadyDisabledNames.Count -gt 0 -and $driverProtectedNames.Count -eq 0)
                                $master.Tag.NoManageableDrivers = $true
                                $master.Tag.AllAlreadyDisabled = $allAlreadyDisabled
                                $master.Tag.UnavailableMessage = $explanation
                                $master.Content = if ($allAlreadyDisabled) {
                                    if ($isSpanish) { "$($entryInfo.Content) (ya desactivados)" } else { "$($entryInfo.Content) (already disabled)" }
                                } elseif ($isSpanish) {
                                    "$($entryInfo.Content) (0 disponibles)"
                                } else {
                                    "$($entryInfo.Content) (0 available)"
                                }
                                $master.ToolTip = $explanation
                            }
                        }
                        Update-WinUtilServiceGroupMaster -GroupName $entryInfo.Name
                        $master.Add_Checked({
                            if ($this.Tag.Updating) { return }
                            if ($this.Tag.NoManageableDrivers) {
                                Show-WinUtilMessage -Title 'APBOptimizer - Drivers' -Message $this.Tag.UnavailableMessage -Icon 'Information' -Button 'OK' | Out-Null
                                Update-WinUtilServiceGroupMaster -GroupName $this.Name
                                return
                            }
                            $this.Tag.Updating = $true
                            try {
                                foreach ($childKey in @($this.Tag.Children)) {
                                    $child = $sync[$childKey]
                                    if ($null -ne $child -and $child.IsEnabled) { $child.IsChecked = $true }
                                }
                            } finally { $this.Tag.Updating = $false }
                            Update-WinUtilServiceGroupMaster -GroupName $this.Name
                        })
                        $master.Add_Unchecked({
                            if ($this.Tag.Updating) { return }
                            if ($this.Tag.NoManageableDrivers) {
                                Show-WinUtilMessage -Title 'APBOptimizer - Drivers' -Message $this.Tag.UnavailableMessage -Icon 'Information' -Button 'OK' | Out-Null
                                Update-WinUtilServiceGroupMaster -GroupName $this.Name
                                return
                            }
                            $this.Tag.Updating = $true
                            try {
                                foreach ($childKey in @($this.Tag.Children)) {
                                    $child = $sync[$childKey]
                                    if ($null -ne $child -and $child.IsEnabled) { $child.IsChecked = $false }
                                }
                            } finally { $this.Tag.Updating = $false }
                            Update-WinUtilServiceGroupMaster -GroupName $this.Name
                        })
                    }
                    "Toggle" {
                        $dockPanel = New-Object Windows.Controls.DockPanel
                        [System.Windows.Automation.AutomationProperties]::SetName($dockPanel, $entryInfo.Content)
                        $checkBox = New-Object Windows.Controls.CheckBox
                        $checkBox.Name = $entryInfo.Name
                        $checkBox.HorizontalAlignment = "Right"
                        $checkBox.UseLayoutRounding = $true
                        [System.Windows.Automation.AutomationProperties]::SetName($checkBox, $entryInfo.Content)
                        $dockPanel.Children.Add($checkBox) | Out-Null
                        $checkBox.Style = $ColorfulToggleSwitchStyle

                        $label = New-Object Windows.Controls.Label
                        $label.Content = $entryInfo.Content
                        $label.ToolTip = $entryInfo.Description
                        $label.HorizontalAlignment = "Left"
                        $label.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "FontSize")
                        $label.SetResourceReference([Windows.Controls.Control]::ForegroundProperty, "MainForegroundColor")
                        $label.UseLayoutRounding = $true
                        $dockPanel.Children.Add($label) | Out-Null
                        $stackPanelContainer.Children.Add($dockPanel) | Out-Null

                        $sync[$entryInfo.Name] = $checkBox
                        $sync[$entryInfo.Name].IsChecked = (Get-WinUtilToggleStatus $entryInfo.Name)

                        $sync[$entryInfo.Name].Add_Checked({
                            [System.Object]$Sender = $args[0]
                            Invoke-WPFSelectedCheckboxesUpdate -type "Add" -checkboxName $Sender.name
                            # Skip applying tweaks while an import is restoring toggle states
                            if (-not $sync.ImportInProgress) {
                                Invoke-WinUtilTweaks $Sender.name
                            }
                        })

                        $sync[$entryInfo.Name].Add_Unchecked({
                            [System.Object]$Sender = $args[0]
                            Invoke-WPFSelectedCheckboxesUpdate -type "Remove" -checkboxName $Sender.name
                            # Skip undoing tweaks while an import is restoring toggle states
                            if (-not $sync.ImportInProgress) {
                                Invoke-WinUtiltweaks $Sender.name -undo $true
                            }
                        })
                    }

                    "ToggleButton" {
                        $toggleButton = New-Object Windows.Controls.Primitives.ToggleButton
                        $toggleButton.Name = $entryInfo.Name
                        $toggleButton.Content = $entryInfo.Content[1]
                        $toggleButton.ToolTip = Get-WinUtilEntryToolTip -Description $entryInfo.Description -Key $entryInfo.Name
                        $toggleButton.HorizontalAlignment = "Left"
                        $toggleButton.Style = $ToggleButtonStyle
                        [System.Windows.Automation.AutomationProperties]::SetName($toggleButton, $entryInfo.Content[0])

                        $toggleButton.Tag = @{
                            contentOn = if ($entryInfo.Content.Count -ge 1) { $entryInfo.Content[0] } else { "" }
                            contentOff = if ($entryInfo.Content.Count -ge 2) { $entryInfo.Content[1] } else { $contentOn }
                        }

                        $stackPanelContainer.Children.Add($toggleButton) | Out-Null

                        $sync[$entryInfo.Name] = $toggleButton

                        $sync[$entryInfo.Name].Add_Checked({
                            $this.Content = $this.Tag.contentOn
                        })

                        $sync[$entryInfo.Name].Add_Unchecked({
                            $this.Content = $this.Tag.contentOff
                        })

                        if ($null -eq $sync.Buttons) {
                            $sync.Buttons = [System.Collections.Generic.List[PSObject]]::new()
                        }

                        if ($sync.Buttons -notcontains $toggleButton.Name) {
                            $toggleButton.Add_Click({
                                [System.Object]$Sender = $args[0]
                                Invoke-WPFButton $Sender.name
                            })
                            $sync.Buttons.Add($toggleButton.Name) | Out-Null
                        }
                    }

                    "Combobox" {
                        $horizontalStackPanel = New-Object Windows.Controls.StackPanel
                        $horizontalStackPanel.Orientation = "Horizontal"
                        $horizontalStackPanel.Margin = "0,5,0,0"
                        [System.Windows.Automation.AutomationProperties]::SetName($horizontalStackPanel, $entryInfo.Content)

                        $label = New-Object Windows.Controls.Label
                        $label.Content = $entryInfo.Content
                        $label.HorizontalAlignment = "Left"
                        $label.ToolTip = $entryInfo.Description
                        $label.VerticalAlignment = "Center"
                        $label.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "ButtonFontSize")
                        $label.UseLayoutRounding = $true
                        $horizontalStackPanel.Children.Add($label) | Out-Null

                        $comboBox = New-Object Windows.Controls.ComboBox
                        $comboBox.Name = $entryInfo.Name
                        $comboBox.SetResourceReference([Windows.Controls.Control]::HeightProperty, "ButtonHeight")
                        $comboBox.SetResourceReference([Windows.Controls.Control]::WidthProperty, "ButtonWidth")
                        $comboBox.HorizontalAlignment = "Left"
                        $comboBox.VerticalAlignment = "Center"
                        $comboBox.SetResourceReference([Windows.Controls.Control]::MarginProperty, "ButtonMargin")
                        $comboBox.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "ButtonFontSize")
                        $comboBox.UseLayoutRounding = $true
                        $comboBox.Tag = [pscustomobject]@{
                            Registry = $entryInfo.Registry
                            State = $null
                        }
                        [System.Windows.Automation.AutomationProperties]::SetName($comboBox, $entryInfo.Content)

                        $comboItems = if ($entryInfo.ComboItems -is [string]) {
                            if ($entryInfo.ComboItems.Contains("|")) {
                                $entryInfo.ComboItems -split "\|"
                            } else {
                                $entryInfo.ComboItems -split " "
                            }
                        } else {
                            @($entryInfo.ComboItems)
                        }

                        foreach ($comboitem in $comboItems) {
                            $comboBoxItem = New-Object Windows.Controls.ComboBoxItem
                            # Keep registry/DNS identifiers as Tag; only localize the
                            # visible labels, never the underlying system value.
                            $comboBoxItem.Tag = $comboitem
                            $localizedOption = if ($entryInfo.LocalizedComboItems) {
                                $entryInfo.LocalizedComboItems.PSObject.Properties[[string]$comboitem]
                            } else { $null }
                            $comboBoxItem.Content = if ($localizedOption) { $localizedOption.Value } else { $comboitem }
                            if ($entryInfo.ComboDescriptions) {
                                $comboDescription = $entryInfo.ComboDescriptions.PSObject.Properties[$comboitem].Value
                                if ($entryInfo.LocalizedComboDescriptions -and $entryInfo.LocalizedComboDescriptions.PSObject.Properties[[string]$comboitem]) {
                                    $comboDescription = $entryInfo.LocalizedComboDescriptions.PSObject.Properties[[string]$comboitem].Value
                                }
                                if ($comboDescription) {
                                    $comboBoxItem.ToolTip = $comboDescription
                                }
                            }
                            $comboBoxItem.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "ButtonFontSize")
                            $comboBoxItem.UseLayoutRounding = $true
                            $comboBox.Items.Add($comboBoxItem) | Out-Null
                        }

                        $horizontalStackPanel.Children.Add($comboBox) | Out-Null
                        $stackPanelContainer.Children.Add($horizontalStackPanel) | Out-Null

                        if ($entryInfo.Registry -and @($entryInfo.Registry)[0].Values) {
                            try {
                                $comboBox.Tag.State = Get-WinUtilRegistryComboState -Registry $entryInfo.Registry
                                $comboBox.SelectedIndex = @($comboBox.Items | ForEach-Object { $_.Tag }).IndexOf([string]$comboBox.Tag.State)
                            } catch {
                                $unknownStateItem = New-Object Windows.Controls.ComboBoxItem
                                $unknownStateItem.Content = if ($sync.Language -eq 'es') { 'Personalizado / Desconocido: elige una opción' } else { 'Custom / Unknown - select a state' }
                                $unknownStateItem.IsEnabled = $false
                                $unknownStateItem.ToolTip = "$($_.Exception.Message) Select one of the supported states to replace these values."
                                $comboBox.Items.Add($unknownStateItem) | Out-Null
                                $comboBox.SelectedItem = $unknownStateItem
                                $comboBox.ToolTip = $unknownStateItem.ToolTip
                            }
                        } else {
                            $comboBox.SelectedIndex = 0
                        }

                        # Set initial text
                        if ($comboBox.Items.Count -gt 0) {
                            $comboBox.Text = $comboBox.SelectedItem.Content
                        }

                        $sync[$entryInfo.Name] = $comboBox

                        # Add SelectionChanged event handler to update the text property
                        $comboBox.Add_SelectionChanged({
                            $selectedItem = $this.SelectedItem
                            if ($selectedItem) {
                                $this.Text = $selectedItem.Content
                                $registry = $this.Tag.Registry
                                $stateValue = [string]$selectedItem.Tag
                                if ($registry -and $selectedItem.IsEnabled -and $stateValue -ne $this.Tag.State) {
                                    try {
                                        Set-WinUtilRegistryComboState -Registry $registry -State $stateValue
                                        $this.Tag.State = $stateValue
                                        $this.ToolTip = $null
                                        $unknownStateItem = @($this.Items) | Where-Object { -not $_.IsEnabled } | Select-Object -First 1
                                        if ($unknownStateItem) {
                                            $this.Items.Remove($unknownStateItem)
                                        }
                                    } catch {
                                        $applyError = $_.Exception.Message
                                        if ([string]::IsNullOrWhiteSpace($applyError)) {
                                            $applyError = "Unable to apply registry state '$($selectedItem.Content)'."
                                        }
                                        $previousState = [string]$this.Tag.State
                                        $this.SelectedItem = @($this.Items) | Where-Object { [string]$_.Tag -eq $previousState } | Select-Object -First 1
                                        [System.Windows.MessageBox]::Show(
                                            $applyError,
                                            "WinUtil",
                                            [System.Windows.MessageBoxButton]::OK,
                                            [System.Windows.MessageBoxImage]::Warning
                                        ) | Out-Null
                                    }
                                }
                            }
                        })

                        if ($entryInfo.Description -or $entryInfo.Link) {
                            $textBlock = New-Object Windows.Controls.TextBlock
                            $textBlock.Name = $comboBox.Name + "Link"
                            $textBlock.Text = "(?)"
                            $textBlock.ToolTip = if ($sync.Language -eq 'es') { 'Ver información del ajuste' } else { 'View tweak information' }
                            $textBlock.Style = $HoverTextBlockStyle
                            $textBlock.UseLayoutRounding = $true
                            $textBlock.VerticalAlignment = "Center"
                            $textBlock.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "FontSize")
                            $textBlock.Tag = $comboBox
                            $textBlock.Uid = $entryInfo.Name

                            $textBlock.Add_MouseUp({
                                [System.Object]$Sender = $args[0]
                                Show-WinUtilTweakHelp -Key $Sender.Uid -Anchor $Sender
                            })

                            $horizontalStackPanel.Children.Add($textBlock) | Out-Null
                            $sync[$textBlock.Name] = $textBlock
                        }
                    }

                    "Button" {
                        $button = New-Object Windows.Controls.Button
                        $button.Name = $entryInfo.Name
                        $button.Content = $entryInfo.Content
                        $button.HorizontalAlignment = "Left"
                        $button.SetResourceReference([Windows.Controls.Control]::MarginProperty, "ButtonMargin")
                        $button.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "ButtonFontSize")
                        if ($entryInfo.ButtonWidth) {
                            $baseWidth = [int]$entryInfo.ButtonWidth
                            $button.Width = [math]::Max($baseWidth, 350)
                        }
                        [System.Windows.Automation.AutomationProperties]::SetName($button, $entryInfo.Content)
                        $stackPanelContainer.Children.Add($button) | Out-Null

                        $sync[$entryInfo.Name] = $button

                        if ($null -eq $sync.Buttons) {
                            $sync.Buttons = [System.Collections.Generic.List[PSObject]]::new()
                        }

                        if ($sync.Buttons -notcontains $button.Name) {
                            $button.Add_Click({
                                [System.Object]$Sender = $args[0]
                                Invoke-WPFButton $Sender.name
                            })
                            $sync.Buttons.Add($button.Name) | Out-Null
                        }
                    }

                    "RadioButton" {
                        # Check if a container for this GroupName already exists
                        if (-not $radioButtonGroups.ContainsKey($entryInfo.GroupName)) {
                            # Create a StackPanel for this group
                            $groupStackPanel = New-Object Windows.Controls.StackPanel
                            $groupStackPanel.Orientation = "Vertical"
                            [System.Windows.Automation.AutomationProperties]::SetName($groupStackPanel, $entryInfo.GroupName)
                            $radioButtonGroups[$entryInfo.GroupName] = $groupStackPanel

                            # Add the group container to the ItemsControl
                            $stackPanelContainer.Children.Add($groupStackPanel) | Out-Null
                        }
                        else {
                            # Retrieve the existing group container
                            $groupStackPanel = $radioButtonGroups[$entryInfo.GroupName]
                        }

                        # Create the RadioButton
                        $radioButton = New-Object Windows.Controls.RadioButton
                        $radioButton.Name = $entryInfo.Name
                        $radioButton.GroupName = $entryInfo.GroupName
                        $radioButton.Content = $entryInfo.Content
                        $radioButton.HorizontalAlignment = "Left"
                        $radioButton.SetResourceReference([Windows.Controls.Control]::MarginProperty, "CheckBoxMargin")
                        $radioButton.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "ButtonFontSize")
                        $radioButton.ToolTip = $entryInfo.Description
                        $radioButton.UseLayoutRounding = $true
                        [System.Windows.Automation.AutomationProperties]::SetName($radioButton, $entryInfo.Content)

                        if ($entryInfo.Checked -eq $true) {
                            $radioButton.IsChecked = $true
                        }

                        # Add the RadioButton to the group container
                        $groupStackPanel.Children.Add($radioButton) | Out-Null
                        $sync[$entryInfo.Name] = $radioButton
                    }

                    "Note" {
                        $textBlock = New-Object Windows.Controls.TextBlock
                        $textBlock.TextWrapping = "Wrap"
                        $textBlock.Margin = "5,5,5,5"
                        $textBlock.UseLayoutRounding = $true

                        $bulletBadge = [Windows.Documents.InlineUIContainer]::new((New-WinUtilFossBadge -Size 18 -Round))
                        $bulletBadge.BaselineAlignment = [Windows.BaselineAlignment]::Center

                        $textRun = New-Object Windows.Documents.Run
                        $textRun.Text = " $($entryInfo.Content)"
                        $textRun.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "FontSize")
                        $textRun.Foreground = [Windows.Media.SolidColorBrush]::new([Windows.Media.Color]::FromRgb(19, 143, 83))

                        $textBlock.Inlines.Add($bulletBadge)
                        $textBlock.Inlines.Add($textRun)

                        $stackPanelContainer.Children.Add($textBlock) | Out-Null
                    }

                    default {
                        $horizontalStackPanel = New-Object Windows.Controls.StackPanel
                        $horizontalStackPanel.Orientation = "Horizontal"
                        [System.Windows.Automation.AutomationProperties]::SetName($horizontalStackPanel, $entryInfo.Content)

                        $checkBox = New-Object Windows.Controls.CheckBox
                        $checkBox.Name = $entryInfo.Name
                        $checkBox.Content = $entryInfo.Content
                        $checkBox.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "FontSize")
                        $checkBox.ToolTip = Get-WinUtilEntryToolTip -Description $entryInfo.Description -Key $entryInfo.Name
                        $checkBox.SetResourceReference([Windows.Controls.Control]::MarginProperty, "CheckBoxMargin")
                        $checkBox.UseLayoutRounding = $true
                        [System.Windows.Automation.AutomationProperties]::SetName($checkBox, $entryInfo.Content)
                        if ($entryInfo.Checked -eq $true) {
                            $checkBox.IsChecked = $entryInfo.Checked
                        }
                        $horizontalStackPanel.Children.Add($checkBox) | Out-Null

                        if ($entryInfo.Description -or $entryInfo.Link) {
                            $textBlock = New-Object Windows.Controls.TextBlock
                            $textBlock.Name = $checkBox.Name + "Link"
                            $textBlock.Text = "(?)"
                            $textBlock.ToolTip = if ($sync.Language -eq 'es') { 'Ver información del ajuste' } else { 'View tweak information' }
                            $textBlock.Style = $HoverTextBlockStyle
                            $textBlock.UseLayoutRounding = $true

                            $textBlock.VerticalAlignment = "Center"
                            $textBlock.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "FontSize")
                            $textBlock.Tag = $checkBox
                            $textBlock.Uid = $entryInfo.Name

                            $textBlock.Add_MouseUp({
                                [System.Object]$Sender = $args[0]
                                Show-WinUtilTweakHelp -Key $Sender.Uid -Anchor $Sender
                            })

                            $updateLinkMargin = {
                                [System.Object]$Sender = $args[0]
                                $linkedCheckBox = $Sender.Tag
                                $MarginTopBase = if ($linkedCheckBox) { $linkedCheckBox.Margin.Top } else { 0 }
                                $Sender.Margin = New-Object Windows.Thickness(
                                    [math]::Round($Sender.FontSize * 0.5),
                                    ($MarginTopBase - [math]::Round($Sender.FontSize / 2)),
                                    0, 0
                                )
                            }
                            $textBlock.Add_Loaded($updateLinkMargin)
                            $fontSizeDescriptor = [System.ComponentModel.DependencyPropertyDescriptor]::FromProperty(
                                [Windows.Controls.Control]::FontSizeProperty,
                                [Windows.Controls.TextBlock]
                            )
                            $fontSizeDescriptor.AddValueChanged($textBlock, $updateLinkMargin)

                            $horizontalStackPanel.Children.Add($textBlock) | Out-Null

                            $sync[$textBlock.Name] = $textBlock
                        }

                        $stackPanelContainer.Children.Add($horizontalStackPanel) | Out-Null
                        $sync[$entryInfo.Name] = $checkBox

                        $sync[$entryInfo.Name].Add_Checked({
                            [System.Object]$Sender = $args[0]
                            Invoke-WPFSelectedCheckboxesUpdate -type "Add" -checkboxName $Sender.name
                        })

                        $sync[$entryInfo.Name].Add_Unchecked({
                            [System.Object]$Sender = $args[0]
                            Invoke-WPFSelectedCheckboxesUpdate -type "Remove" -checkboxName $Sender.name
                        })
                    }
                }
            }
        }
    }

    # A search event can run inside one of the yielded dispatcher frames above. Controls added
    # after that event start visible, so reapply the live filter once this tab is complete.
    $filterPanel = switch ($sync.currentTab) {
        "Tweaks" { "tweakspanel" }
        "AppX" { "appxpanel" }
    }
    if ($filterPanel -eq $targetGridName -and $null -ne $sync.SearchBar) {
        Find-TweaksByNameOrDescription -SearchString $sync.SearchBar.Text
    }
}

function Test-WinUtilUIAlive {
    <#
        .SYNOPSIS
            Whether there is a window that can still be posted to

        .DESCRIPTION
            False for a headless run, and for a window closed over running work: a shut down
            dispatcher accepts posts and discards them.
    #>

    return $null -ne $sync.Form -and $null -ne $sync.Form.Dispatcher -and -not $sync.Form.Dispatcher.HasShutdownStarted
}

function Test-WinUtilDispatcherShutdownException {
    param([System.Exception]$Exception)

    while ($null -ne $Exception) {
        if ($Exception -is [System.OperationCanceledException] -or
            $Exception -is [System.InvalidOperationException]) {
            return $true
        }
        $Exception = $Exception.InnerException
    }

    return $false
}

function Invoke-WPFUIThread {
    <#
        .SYNOPSIS
            Runs a scriptblock on the interface thread

        .DESCRIPTION
            Controls may only be touched from the thread that owns the window.

            The body is handed over as text and rebuilt in the interface runspace rather than
            marshalled as a scriptblock: a scriptblock keeps the session state it was written in,
            and running one across runspaces costs roughly twenty times as much per command. So
            values come in through Parameters rather than captured from the caller's scope.

            A no-op once the window is gone, so a job outliving the interface finishes quietly.

        .PARAMETER ScriptBlock
            The work to run on the interface thread. Declare a param block for anything it needs.

        .PARAMETER Parameters
            Values passed to the body by name.

        .PARAMETER Async
            Post and return instead of waiting. For progress and log updates, which must never
            stall the caller.

        .PARAMETER PassThru
            Return what the body produced. Off by default so a caller that only wanted a control
            updated gets no stray output.
    #>
    param(
        [Parameter(Mandatory, Position = 0)]
        [scriptblock]$ScriptBlock,

        [hashtable]$Parameters = @{},

        [switch]$Async,

        [switch]$PassThru
    )

    if (-not (Test-WinUtilUIAlive)) {
        return
    }
    $dispatcher = $sync.Form.Dispatcher

    if (-not $Async -and $dispatcher.CheckAccess()) {
        $inlineResult = & $ScriptBlock @Parameters
        if ($PassThru) { return $inlineResult }
        return
    }

    $executor = $sync.UIDispatchDelegate
    if ($null -eq $executor) {
        # No interface runspace to hand the work to, so the block itself is marshalled. It has to
        # receive its parameters and return what it produced, and [action] carries neither.
        if ($Async) {
            # The values travel as the dispatcher's argument, since this call returns before the
            # block runs and anything captured from here would be gone by then
            try {
                $null = $dispatcher.BeginInvoke(
                    [Windows.Threading.DispatcherPriority]::Background,
                    [System.Windows.Threading.DispatcherOperationCallback]{
                        param($Work)
                        $body = $Work.Body
                        $arguments = $Work.Parameters
                        if ($arguments -and $arguments.Count -gt 0) {
                            $null = & $body @arguments
                        } else {
                            $null = & $body
                        }
                        return $null
                    },
                    @{ Body = $ScriptBlock; Parameters = $Parameters })
            } catch {
                $shutdownFailure = Test-WinUtilDispatcherShutdownException -Exception $_.Exception
                if ($shutdownFailure -and -not (Test-WinUtilUIAlive)) { return }
                throw
            }
            return
        }

        # Synchronous, so this frame is still alive while the block runs and can be captured from
        try {
            $fallbackResult = $dispatcher.Invoke([System.Func[object]]{ & $ScriptBlock @Parameters })
        } catch {
            $shutdownFailure = Test-WinUtilDispatcherShutdownException -Exception $_.Exception
            if ($shutdownFailure -and -not (Test-WinUtilUIAlive)) { return }
            throw
        }
        if ($PassThru) { return $fallbackResult }
        return
    }

    $work = @{
        Body = $ScriptBlock.ToString()
        Parameters = $Parameters
        # A synchronous caller is waiting for a required UI handoff and must see its failure.
        # Fire-and-forget posts have nobody to receive an exception, so the delegate only logs it.
        PropagateErrors = -not $Async
    }

    if ($Async) {
        try {
            $null = $dispatcher.BeginInvoke([Windows.Threading.DispatcherPriority]::Background, $executor, $work)
        } catch {
            $shutdownFailure = Test-WinUtilDispatcherShutdownException -Exception $_.Exception
            if ($shutdownFailure -and -not (Test-WinUtilUIAlive)) { return }
            throw
        }
        return
    }

    try {
        $result = $dispatcher.Invoke($executor, @($work))
    } catch {
        $shutdownFailure = Test-WinUtilDispatcherShutdownException -Exception $_.Exception
        if ($shutdownFailure -and -not (Test-WinUtilUIAlive)) { return }
        throw
    }
    if ($PassThru) { return $result }
}

function Invoke-WPFUltimatePerformance ([switch]$Enable) {
    <#

    .SYNOPSIS
        Adds or removes the Ultimate Performance power plan

    #>

    if ($Enable) {
        Step-WinUtilJob -Status "Adding the Ultimate Performance power plan" -State "Indeterminate"
        Write-WinUtilLog -Component "Power" -Message "Duplicating and activating the Ultimate Performance power plan."

        $duplicated = powercfg /duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61
        if ($LASTEXITCODE -ne 0) {
            throw "powercfg could not duplicate the Ultimate Performance scheme (exit code $LASTEXITCODE)."
        }

        $guid = ($duplicated | Select-String -Pattern '[A-Fa-f0-9-]{36}').Matches.Value
        if (-not $guid) {
            throw "powercfg did not report a scheme GUID to activate."
        }

        powercfg /setactive $guid
        if ($LASTEXITCODE -ne 0) {
            throw "powercfg could not activate the Ultimate Performance scheme (exit code $LASTEXITCODE)."
        }

        Write-WinUtilLog -Component "Power" -Message "Ultimate Performance power plan installed and activated."
    } else {
        Step-WinUtilJob -Status "Restoring the default power plans" -State "Indeterminate"
        Write-WinUtilLog -Component "Power" -Message "Restoring the default power schemes."

        powercfg /restoredefaultschemes
        if ($LASTEXITCODE -ne 0) {
            throw "powercfg could not restore the default power schemes (exit code $LASTEXITCODE)."
        }

        Write-WinUtilLog -Component "Power" -Message "Power plans were reset to defaults."
    }
}

function Invoke-WPFundoall {
    <#

    .SYNOPSIS
        Undoes every selected tweak

    #>

    $tweaks = @($sync.selectedTweaks)

    if ($tweaks.count -eq 0) {
        Show-WinUtilMessage -Message "Please check the tweaks you wish to undo." -Title "WinUtil" -Button "OK" -Icon "Warning"
        return
    }

    # AppX packages do not have an inverse action: Undo must not falsely report
    # that a bulk uninstall was reversed. Other selected tweaks are still undoable.
    if ($tweaks -contains 'WPFTweaksDeBloat') {
        $warning = if ($sync.Language -eq 'es') {
            'Eliminar apps de Microsoft Store no se puede deshacer automaticamente. Debes reinstalar las aplicaciones manualmente. Los otros ajustes seleccionados se pueden restaurar por separado.'
        } else {
            'Bulk Microsoft Store app removal has no automatic Undo. You must reinstall removed apps manually. Other selected tweaks can still be restored.'
        }
        Show-WinUtilMessage -Message $warning -Title 'APBOptimizer - MS Store Apps' -Button 'OK' -Icon 'Warning' | Out-Null
        $tweaks = @($tweaks | Where-Object { $_ -ne 'WPFTweaksDeBloat' })
        if ($tweaks.Count -eq 0) { return }
    }

    Start-WinUtilJob -Name "Undo tweaks" -Description "Undoing tweaks" -Parameters @{
        Tweaks = @($tweaks)
    } -ScriptBlock {
        param($Tweaks)

        $total = @($Tweaks).Count
        Write-WinUtilLog -Component "Tweaks" -Message "Undo tweaks requested: $total selected tweak(s)."

        for ($i = 0; $i -lt $total; $i++) {
            Step-WinUtilJob -Status "Undoing $($Tweaks[$i]) ($($i + 1)/$total)" -Percent ([int](($i / $total) * 100))
            Measure-WinUtilStep -Scope "Undo tweaks" -Name $Tweaks[$i] -ScriptBlock {
                Invoke-WinUtiltweaks $Tweaks[$i] -undo $true
            }
            Step-WinUtilJob -Percent ([int]((($i + 1) / $total) * 100))
        }
    }
}

$sync.configs.dns = @'
{
    "Google":  {
                   "BenchmarkEligible":  true,
                   "Primary":  "8.8.8.8",
                   "Secondary":  "8.8.4.4",
                   "Primary6":  "2001:4860:4860::8888",
                   "Secondary6":  "2001:4860:4860::8844",
                   "DohTemplate":  "https://dns.google/dns-query"
               },
    "Cloudflare":  {
                       "BenchmarkEligible":  true,
                       "Primary":  "1.1.1.1",
                       "Secondary":  "1.0.0.1",
                       "Primary6":  "2606:4700:4700::1111",
                       "Secondary6":  "2606:4700:4700::1001",
                       "DohTemplate":  "https://cloudflare-dns.com/dns-query"
                   },
    "Cloudflare_Malware":  {
                               "Primary":  "1.1.1.2",
                               "Secondary":  "1.0.0.2",
                               "Primary6":  "2606:4700:4700::1112",
                               "Secondary6":  "2606:4700:4700::1002",
                               "DohTemplate":  "https://security.cloudflare-dns.com/dns-query"
                           },
    "Cloudflare_Malware_Adult":  {
                                     "Primary":  "1.1.1.3",
                                     "Secondary":  "1.0.0.3",
                                     "Primary6":  "2606:4700:4700::1113",
                                     "Secondary6":  "2606:4700:4700::1003",
                                     "DohTemplate":  "https://family.cloudflare-dns.com/dns-query"
                                 },
    "Open_DNS":  {
                     "Primary":  "208.67.222.222",
                     "Secondary":  "208.67.220.220",
                     "Primary6":  "2620:119:35::35",
                     "Secondary6":  "2620:119:53::53",
                     "DohTemplate":  "https://doh.opendns.com/dns-query"
                 },
    "Quad9":  {
                  "Primary":  "9.9.9.9",
                  "Secondary":  "149.112.112.112",
                  "Primary6":  "2620:fe::fe",
                  "Secondary6":  "2620:fe::9",
                  "DohTemplate":  "https://dns.quad9.net/dns-query"
              },
    "AdGuard_Ads_Trackers":  {
                                 "Primary":  "94.140.14.14",
                                 "Secondary":  "94.140.15.15",
                                 "Primary6":  "2a10:50c0::ad1:ff",
                                 "Secondary6":  "2a10:50c0::ad2:ff",
                                 "DohTemplate":  "https://dns.adguard-dns.com/dns-query"
                             },
    "AdGuard_Ads_Trackers_Malware_Adult":  {
                                               "Primary":  "94.140.14.15",
                                               "Secondary":  "94.140.15.16",
                                               "Primary6":  "2a10:50c0::bad1:ff",
                                               "Secondary6":  "2a10:50c0::bad2:ff",
                                               "DohTemplate":  "https://family.adguard-dns.com/dns-query"
                                           }
}
'@ | ConvertFrom-Json
$sync.configs.es = @'
{
    "WPFTweaksActivity":  {
                              "Content":  "Historial de actividad: desactivar",
                              "Description":  "Impide que Windows publique o envíe las actividades del usuario. Conserva el historial del portapapeles."
                          },
    "WPFTweaksHiber":  {
                           "Content":  "Hibernación: desactivar",
                           "Description":  "Desactiva la hibernación, que guarda el contenido de la memoria antes de apagar el equipo. Esta función puede ser útil en portátiles."
                       },
    "WPFTweaksWidget":  {
                            "Content":  "Widgets: eliminar",
                            "Description":  "Elimina los widgets que aparecen en la esquina inferior izquierda de la barra de tareas."
                        },
    "WPFTweaksRevertStartMenu":  {
                                     "Content":  "Menú Inicio clásico: restaurar",
                                     "Description":  "Restaura el diseño del menú Inicio anterior al cambio gradual de Windows 25H2. ¡Esta opción no funciona en versiones más recientes de Windows!"
                                 },
    "WPFTweaksDisableStoreSearch":  {
                                        "Content":  "Sugerencias de Microsoft Store: desactivar",
                                        "Description":  "Oculta las aplicaciones recomendadas de Microsoft Store al buscar programas desde el menú Inicio."
                                    },
    "WPFTweaksLocation":  {
                              "Content":  "Seguimiento de ubicación: desactivar",
                              "Description":  "Desactiva el seguimiento de ubicación de Windows."
                          },
    "WPFTweaksServices":  {
                              "Content":  "Servicios: ajustar inicio",
                              "Description":  "Configura varios servicios para inicio manual o deshabilitado y ajusta SvcHostSplitThresholdInKB según la memoria del equipo. Puede reducir significativamente la cantidad de procesos svchost.exe."
                          },
    "WPFServiceGroupDiagnostics":  {
                                       "Content":  "Desactivar servicios de diagnóstico",
                                       "Description":  "Despliega la flecha para elegir servicios de diagnóstico y telemetría de Windows: hosts de diagnóstico, Servicio de directivas de diagnóstico, DiagTrack, Informe de errores y el recopilador de Diagnostics Hub. Marcar o desmarcar solo prepara los cambios; pulsa Aplicar ajustes para desactivar los seleccionados o restaurar los desmarcados. La casilla principal selecciona todos los disponibles. Al desactivarlos dejan de funcionar los solucionadores de problemas, la detección de problemas y los informes de errores."
                                   },
    "WPFServiceGroupUseless":  {
                                   "Content":  "Desactivar servicios innecesarios",
                                   "Description":  "Despliega la flecha para elegir servicios opcionales de Windows. Marcar o desmarcar solo prepara los cambios; pulsa Aplicar ajustes para desactivar los seleccionados o restaurar los desmarcados. La casilla principal selecciona todos los disponibles. Algunos servicios son importantes para la reproducción automática, la administración de dispositivos o las redes .NET. NetTcpPortSharing suele venir desactivado de fábrica; restaurarlo lo pone en inicio manual."
                               },
    "WPFToggleServiceWdiSystemHost":  {
                                          "Content":  "Host de diagnóstico del sistema (WdiSystemHost)",
                                          "Description":  "Lo utiliza el servicio de directivas de diagnóstico de Windows para resolver problemas del sistema. Desactivarlo impide algunos diagnósticos. Revertir restaura el inicio manual."
                                      },
    "WPFToggleServiceWdiServiceHost":  {
                                           "Content":  "Host del servicio de diagnóstico (WdiServiceHost)",
                                           "Description":  "Ejecuta diagnósticos con permisos de servicio local. Desactivarlo impide algunas funciones de solución de problemas. Revertir restaura el inicio manual."
                                       },
    "WPFToggleServiceDiagTrack":  {
                                      "Content":  "Experiencias de usuario conectadas (DiagTrack)",
                                      "Description":  "Servicio de telemetría y diagnóstico de Windows. Puede estar desactivado por el ajuste de telemetría. Revertir restaura el inicio automático."
                                  },
    "WPFToggleServiceShellHWDetection":  {
                                             "Content":  "Detección de hardware (ShellHWDetection)",
                                             "Description":  "Muestra notificaciones de reproducción automática al conectar medios y dispositivos. Desactivarlo elimina esos avisos y puede afectar funciones relacionadas. Revertir restaura el inicio automático."
                                         },
    "WPFToggleServiceDPS":  {
                                "Content":  "Servicio de directivas de diagnóstico (DPS)",
                                "Description":  "Necesario para detectar y resolver problemas de Windows. Microsoft recomienda mantenerlo activo. Desactivarlo puede impedir los diagnósticos. Revertir restaura el inicio automático."
                            },
    "WPFToggleServiceWMPNetworkSvc":  {
                                          "Content":  "Compartir multimedia en red (WMPNetworkSvc)",
                                          "Description":  "Comparte bibliotecas del Reproductor de Windows Media con dispositivos de la red. Desactivarlo detiene ese uso compartido. Revertir restaura el inicio manual. Puede no existir en algunas instalaciones."
                                      },
    "WPFToggleServicewisvc":  {
                                  "Content":  "Servicio Windows Insider (wisvc)",
                                  "Description":  "Se utiliza para recibir versiones de prueba del programa Windows Insider. Desactivarlo puede afectar ese programa. Revertir restaura el inicio manual. El servicio puede no estar instalado."
                              },
    "WPFToggleServiceWerSvc":  {
                                   "Content":  "Informes de errores de Windows (WerSvc)",
                                   "Description":  "Recopila e informa sobre fallos de aplicaciones y del sistema. Desactivarlo reduce los informes y la información de diagnóstico. Revertir restaura el inicio manual."
                               },
    "WPFToggleServiceFontCache3000":  {
                                          "Content":  "Caché de fuentes WPF (FontCache3.0.0.0)",
                                          "Description":  "Almacena fuentes en caché para aplicaciones antiguas de Windows Presentation Foundation. Desactivarlo puede ralentizar algunas aplicaciones .NET/WPF. Suele faltar en Windows recientes. Revertir restaura el inicio manual."
                                      },
    "WPFToggleServiceRetailDemo":  {
                                       "Content":  "Servicio de demostración comercial (RetailDemo)",
                                       "Description":  "Permite mostrar experiencias de demostración en equipos de tiendas. Desactivarlo impide usar el modo de demostración comercial. Revertir restaura el inicio manual."
                                   },
    "WPFToggleServiceDiagnosticsHub":  {
                                           "Content":  "Recopilador de diagnósticos (diagnosticshub.standardcollector.service)",
                                           "Description":  "Recopila eventos de seguimiento de Windows (ETW) para herramientas de diagnóstico y desarrollo. Desactivarlo puede afectar la captura de trazas y los analizadores de rendimiento. Revertir restaura el inicio manual."
                                       },
    "WPFToggleServiceDmwappushservice":  {
                                             "Content":  "Administración de dispositivos WAP Push (dmwappushservice)",
                                             "Description":  "Gestiona mensajes de administración remota de dispositivos. Desactivarlo puede interrumpir Intune, la administración MDM y la inscripción de dispositivos. Revertir restaura el inicio manual."
                                         },
    "WPFToggleServiceWhesvc":  {
                                   "Content":  "Salud y experiencias optimizadas de Windows (whesvc)",
                                   "Description":  "Supervisa la salud del dispositivo para optimizar funciones de Windows. Desactivarlo puede afectar esas funciones; no existe en todas las versiones. Revertir restaura el inicio automático y arranca el servicio."
                               },
    "WPFToggleServiceNetTcpPortSharing":  {
                                              "Content":  "Uso compartido de puertos Net.TCP (NetTcpPortSharing)",
                                              "Description":  "Permite que aplicaciones Windows Communication Foundation compartan puertos TCP. Windows suele traerlo deshabilitado, por eso su casilla puede aparecer marcada. Al desmarcarlo queda en inicio manual sin arrancarlo, para aplicaciones que usan WCF."
                                          },
    "WPFTweaksDisableWindowsSearch":  {
                                          "Content":  "Indexación de Windows Search: desactivar",
                                          "Description":  "Detiene el servicio Windows Search (WSearch) y desactiva su inicio. Reduce la indexación en segundo plano, pero puede ralentizar o impedir las búsquedas de archivos, Inicio y Outlook. Revertir restaura el inicio automático diferido y vuelve a iniciar el servicio."
                                      },
    "WPFTweaksDisableSearchWebView2":  {
                                           "Content":  "Procesos WebView2 de la búsqueda de Inicio: desactivar [reinicio]",
                                           "Description":  "Evita que SearchHost.exe mantenga procesos msedgewebview2.exe abiertos en segundo plano. Escribe en el Registro el mismo cambio que \u0027vivetool /disable /id:37926450\u0027 (SearchWebView2), sin ejecutar ViVeTool. También desactiva la nueva interfaz de búsqueda del menú Inicio. Microsoft puede renombrar o quitar esta función en una actualización y entonces el cambio deja de tener efecto. Requiere reiniciar. Revertir quita el cambio."
                                       },
    "WPFDriverGroupOptional":  {
                                   "Content":  "Desactivar drivers innecesarios",
                                   "Description":  "Opciones avanzadas: marcar o desmarcar solo prepara los cambios. Pulsa Aplicar ajustes para realizarlos; antes de desactivar drivers aparece una confirmación. Se guarda la configuración original para restaurarla y se requiere reiniciar. Los drivers Boot/System y críticos están protegidos y los ausentes se ocultan. No se borran archivos .sys. Puede afectar DRM, red y energía; UCPD.sys tiene un ajuste independiente."
                               },
    "WPFToggleDriverTelemetry":  {
                                     "Content":  "Telemetría Intel (Telemetry / 20H2)",
                                     "Description":  "Driver Telemetry de Intel, diferente al servicio DiagTrack. Si Windows ya lo tiene deshabilitado, APBOptimizer no lo cambia ni inventa su configuración original."
                                 },
    "WPFToggleDriverPEAUTH":  {
                                  "Content":  "Medios protegidos (PEAUTH.sys)",
                                  "Description":  "Autenticación de medios protegidos de Windows. Deshabilitar puede impedir reproducir contenido DRM. Solo para sistemas que no lo necesitan y cuando su arranque no sea crítico."
                              },
    "WPFToggleDriverTcpipreg":  {
                                    "Content":  "Compatibilidad TCP/IP (tcpipreg.sys)",
                                    "Description":  "Driver de compatibilidad con aplicaciones que consultan configuraciones TCP/IP antiguas. Desactivarlo puede afectar aplicaciones de red antiguas; no equivale a desactivar tcpip.sys."
                                },
    "WPFToggleDriverIntelPMT":  {
                                    "Content":  "Monitoreo de plataforma Intel (IntelPMT.sys)",
                                    "Description":  "Monitorización de plataforma Intel. Puede participar en diagnóstico y políticas de rendimiento/energía de software Intel o del fabricante."
                                },
    "WPFToggleDriverGpuEnergyDrv":  {
                                        "Content":  "Consumo de GPU (GpuEnergyDrv.sys)",
                                        "Description":  "Driver de Windows que monitoriza energía de GPU. Puede afectar métricas y funciones de ahorro energético, especialmente en portátiles."
                                    },
    "WPFToggleDriverIObitUnlocker":  {
                                         "Content":  "Driver de IObit Unlocker (IObitUnlocker.sys)",
                                         "Description":  "Driver de IObit Unlocker. Puede ser necesario para desbloquear archivos ocupados; si ya no usas el programa, lo preferible es desinstalarlo."
                                     },
    "WPFTweaksDisableUCPD":  {
                                 "Content":  "UCPD.sys y UCPD velocity: desactivar",
                                 "Description":  "Ajuste independiente. UCPD protege las asociaciones predeterminadas del navegador, PDF y otras opciones de Windows. Aplicar guarda el inicio original del driver y el estado de la tarea UCPD velocity; deshabilita ambos sin borrar la tarea. Deshacer restaura sus valores originales. Requiere reiniciar y Windows Update puede reactivarlos. Desactiva una protección de Windows; úsalo solo si es necesario."
                             },
    "WPFTaskGroupTelemetry":  {
                                  "Content":  "Desactivar tareas programadas innecesarias",
                                  "Description":  "Despliega la flecha para elegir tareas de telemetría, compatibilidad, multimedia y Firefox. Marcar o desmarcar solo prepara los cambios: pulsa Aplicar ajustes para desactivar las seleccionadas o restaurar las que APBOptimizer había desactivado. La casilla principal selecciona todas las disponibles. Las tareas ausentes se ocultan y las desactivadas anteriormente sin copia de seguridad quedan protegidas."
                              },
    "WPFToggleTaskCompatibilityAppraiser":  {
                                                "Content":  "Microsoft Compatibility Appraiser",
                                                "Description":  "Evalúa la compatibilidad de las aplicaciones y del equipo con nuevas versiones de Windows. Desactivarlo puede afectar las evaluaciones de actualización."
                                            },
    "WPFToggleTaskProgramDataUpdater":  {
                                            "Content":  "ProgramDataUpdater",
                                            "Description":  "Actualiza los datos de programas utilizados para compatibilidad y diagnósticos. Se puede restaurar al estado anterior."
                                        },
    "WPFToggleTaskConsolidator":  {
                                      "Content":  "Consolidator (CEIP)",
                                      "Description":  "Consolida datos opcionales del programa de experiencia del cliente de Windows."
                                  },
    "WPFToggleTaskUsbCeip":  {
                                 "Content":  "UsbCeip (USB)",
                                 "Description":  "Recopila diagnósticos opcionales sobre el uso de dispositivos USB."
                             },
    "WPFToggleTaskKernelCeip":  {
                                    "Content":  "KernelCeipTask (kernel)",
                                    "Description":  "Recopila datos opcionales de experiencia y diagnóstico del núcleo de Windows."
                                },
    "WPFToggleTaskCompatibilityAppraiserExp":  {
                                                   "Content":  "Microsoft Compatibility Appraiser Exp",
                                                   "Description":  "Tarea adicional de telemetría y compatibilidad de Windows. Desactivarla puede afectar las comprobaciones de compatibilidad para actualizar el sistema."
                                               },
    "WPFToggleTaskWindowsMediaSharing":  {
                                             "Content":  "Windows Media Sharing: UpdateLibrary",
                                             "Description":  "Actualiza la biblioteca multimedia compartida por red. Es opcional si no compartes música, videos o fotos con otros dispositivos."
                                         },
    "WPFToggleTaskUsageDataReporting":  {
                                            "Content":  "Flighting: UsageDataReporting",
                                            "Description":  "Envía informes sobre el uso de características de Windows. Desactivarla puede afectar informes o configuraciones internas de funciones."
                                        },
    "WPFToggleTaskSustainabilityTelemetry":  {
                                                 "Content":  "SustainabilityTelemetry",
                                                 "Description":  "Recopila datos sobre sostenibilidad y energía. No desactiva PowerGridForecastTask."
                                             },
    "WPFToggleTaskFirefoxDefaultBrowserAgent":  {
                                                    "Content":  "Firefox Default Browser Agent",
                                                    "Description":  "Comprueba los cambios de navegador predeterminado. Busca el identificador específico de Firefox automáticamente y guarda el estado de cada tarea encontrada. No desactiva las actualizaciones de Firefox."
                                                },
    "WPFTweaksDisableTelemetryTasks":  {
                                           "Content":  "Tareas de telemetría (compatibilidad anterior)",
                                           "Description":  "Entrada oculta para importar configuraciones antiguas. Las casillas individuales se encuentran en Desactivar tareas programadas innecesarias."
                                       },
    "WPFTweaksPauseWindows2099":  {
                                      "Content":  "Windows Update: pausar hasta 2099",
                                      "Description":  "Pausa experimental mediante fechas del Registro hasta el 17 de agosto de 2099. Microsoft admite oficialmente hasta 35 días, por lo que Windows puede ignorar o reajustar la fecha. Se recomienda activar primero una pausa de 7 días desde Configuración, pero no es obligatorio. Aplicar conserva los valores anteriores y Deshacer los restaura. No cambia servicios, tareas programadas ni DLL protegidas. Si Windows respeta la pausa, tampoco recibirá actualizaciones de seguridad."
                                  },
    "WPFTweaksDisableMemoryIntegrity":  {
                                            "Content":  "Integridad de memoria (HVCI): desactivar [reinicio]",
                                            "Description":  "Ajuste avanzado de Windows 10 y 11. Desactiva la integridad de memoria (HVCI) con Enabled=0 en el Registro y reduce la protección frente a malware del núcleo. Requiere administrador y reiniciar. No desactiva todo VBS, Credential Guard ni el hipervisor. Protege los equipos con políticas o bloqueo UEFI y conserva el valor original (incluso si no existía) para restaurarlo con Deshacer ajustes seleccionados. Se recomienda usar Seguridad de Windows \u003e Seguridad del dispositivo \u003e Aislamiento del núcleo para hacerlo manualmente. La mejora de rendimiento varía según el equipo y el juego; no está garantizada."
                                        },
    "WPFTweaksDisablePowerThrottling":  {
                                            "Content":  "Power Throttling: desactivar [reinicio recomendado]",
                                            "Description":  "Desactiva la limitación de energía de procesos en Windows 10 y 11 estableciendo PowerThrottlingOff=1 en el Registro. Puede beneficiar tareas que Windows limita en segundo plano, pero normalmente no mejora los FPS de juegos en primer plano. Puede aumentar consumo, temperatura, ruido del ventilador y gasto de batería. Requiere administrador; se recomienda reiniciar. No modifica el plan de energía ni otros ajustes de CPU. Guarda el valor original, incluso si no existía, para restaurarlo con Deshacer ajustes seleccionados. Una directiva del sistema puede volver a configurar este valor."
                                        },
    "WPFTweaksDisableDevicePowerSaving":  {
                                              "Content":  "Suspensión selectiva de USB y ahorro de PCIe: desactivar",
                                              "Description":  "Ajuste del plan de energía de Windows 10 y 11. Usa powercfg para desactivar la suspensión selectiva de USB y la administración de energía del estado de vínculos de PCI Express (ASPM) con el equipo enchufado (AC) en el plan activo, y luego vuelve a activar el plan. Puede reducir cortes del mouse, mando o audio USB y la latencia de PCIe; la mejora no está garantizada. No cambia los valores con batería (DC) ni otros planes. El consumo y la temperatura en reposo pueden subir un poco. Requiere administrador; no hace falta reiniciar. Guarda los valores AC originales y el GUID del plan para restaurarlos con Deshacer ajustes seleccionados."
                                          },
    "WPFTweaksDisableCPUMitigations":  {
                                           "Content":  "Disable Mitigations (Spectre/Meltdown) [reinicio]",
                                           "Description":  "Desactiva mitigaciones del sistema operativo contra ataques de ejecución especulativa, entre ellos Spectre variante 2 y Meltdown. Establece FeatureSettingsOverride=3 y FeatureSettingsOverrideMask=3 según el script CPU_Mitigations.bat y la documentación de Microsoft. No desactiva todas las protecciones del procesador ni del firmware. Reduce considerablemente la seguridad, sobre todo al ejecutar software no confiable. La mejora de rendimiento no está garantizada. Requiere administrador y reiniciar Windows. Guarda ambos valores originales del Registro (incluso si no existían) para restaurarlos con Deshacer ajustes seleccionados. No ejecuta ningún programa externo."
                                       },
    "WPFTweaksBraveDebloat":  {
                                  "Content":  "Brave: quitar funciones adicionales",
                                  "Description":  "Desactiva funciones como Brave Rewards, Leo AI, la billetera de criptomonedas y la VPN."
                              },
    "WPFTweaksDisableWarningForUnsignedRdp":  {
                                                  "Content":  "Avisos RDP sin firma: desactivar",
                                                  "Description":  "Desactiva las advertencias al abrir archivos RDP sin firma, introducidas en actualizaciones recientes de Windows 10 y 11."
                                              },
    "WPFTweaksEdgeDebloat":  {
                                 "Content":  "Microsoft Edge: quitar funciones adicionales",
                                 "Description":  "Desactiva varias opciones de telemetría, ventanas emergentes y otras funciones molestas de Microsoft Edge."
                             },
    "WPFTweaksConsumerFeatures":  {
                                      "Content":  "Funciones para consumidores: desactivar",
                                      "Description":  "Evita la instalación de aplicaciones promocionadas y reduce las sugerencias de contenido de Microsoft Store."
                                  },
    "WPFTweaksTelemetry":  {
                               "Content":  "Telemetría: desactivar",
                               "Description":  "Desactiva la telemetría de Microsoft."
                           },
    "WPFTweaksDeliveryOptimization":  {
                                          "Content":  "Optimización de distribución: desactivar",
                                          "Description":  "Impide que Windows utilice tu conexión para subir actualizaciones a otros equipos de Internet o de la red local."
                                      },
    "WPFTweaksRemoveEdge":  {
                                "Content":  "Microsoft Edge: eliminar",
                                "Description":  "Desinstala Microsoft Edge creando un archivo MicrosoftEdge.exe ficticio en la carpeta antigua del navegador. Esto permite desbloquear el desinstalador oficial de Edge y eliminarlo del sistema."
                            },
    "WPFTweaksDisableBitLocker":  {
                                      "Content":  "BitLocker: desactivar",
                                      "Description":  "Desactiva el cifrado de unidades BitLocker."
                                  },
    "WPFTweaksUTC":  {
                         "Content":  "Fecha y hora: usar UTC",
                         "Description":  "Recomendado para equipos con arranque dual. Corrige diferencias de sincronización horaria con Linux."
                     },
    "WPFTweaksRemoveOneDrive":  {
                                    "Content":  "Microsoft OneDrive: eliminar",
                                    "Description":  "Bloquea temporalmente el permiso para eliminar archivos personales de OneDrive, ejecuta su desinstalador y luego restaura el permiso original."
                                },
    "WPFTweaksRemoveHomeAndGallery":  {
                                          "Content":  "Explorador: ocultar Inicio y Galería",
                                          "Description":  "Oculta Inicio y Galería del Explorador de archivos y establece Este equipo como vista predeterminada."
                                      },
    "WPFTweaksDisplay":  {
                             "Content":  "Efectos visuales: máximo rendimiento",
                             "Description":  "Ajusta los efectos visuales de Windows para priorizar el rendimiento. También puedes hacerlo manualmente desde sysdm.cpl."
                         },
    "WPFTweaksReservedStorage":  {
                                     "Content":  "Almacenamiento reservado: desactivar",
                                     "Description":  "Desactiva el almacenamiento reservado de Windows (entre 7 y 10 GB para actualizaciones y archivos temporales). Se recomienda solo en unidades pequeñas. Vuelve a activarlo antes de actualizaciones importantes para evitar errores de instalación."
                                 },
    "WPFTweaksRestorePoint":  {
                                  "Content":  "Punto de restauración: crear",
                                  "Description":  "Crea un punto de restauración del sistema por si necesitas revertir cambios realizados con APBOptimizer."
                              },
    "WPFTweaksEndTaskOnTaskbar":  {
                                      "Content":  "Finalizar tarea con clic derecho: activar",
                                      "Description":  "Permite finalizar una aplicación desde su menú contextual en la barra de tareas."
                                  },
    "WPFTweaksStorage":  {
                             "Content":  "Sensor de almacenamiento: desactivar",
                             "Description":  "Desactiva el Sensor de almacenamiento, que elimina automáticamente archivos temporales."
                         },
    "WPFTweaksWindowsAI":  {
                               "Content":  "IA de Windows: desactivar y eliminar",
                               "Description":  "Elimina y desactiva las funciones y los paquetes de inteligencia artificial de Windows."
                           },
    "WPFTweaksWPBT":  {
                          "Content":  "Tabla binaria de Windows (WPBT): desactivar",
                          "Description":  "WPBT permite que el fabricante ejecute programas al arrancar, como herramientas antirrobo y controladores, e incluso que instale software sin consentimiento. Puede representar un riesgo de seguridad."
                      },
    "WPFTweaksPreventDeviceMetadataFromNetwork":  {
                                                      "Content":  "Impedir aplicaciones de dispositivos",
                                                      "Description":  "Evita la instalación de software adicional al conectar dispositivos, como aplicaciones promocionadas al conectar un monitor. Este mecanismo puede suponer un riesgo de seguridad."
                                                  },
    "WPFTweaksRazerBlock":  {
                                "Content":  "Instalación automática de Razer: bloquear",
                                "Description":  "Bloquea la instalación de todo el software de Razer. Los dispositivos siguen funcionando sin ese software."
                            },
    "WPFTweaksLogiBlock":  {
                               "Content":  "Instalación automática de Logitech: bloquear",
                               "Description":  "Bloquea Logitech Download Assistant, que Windows Update reinstala junto con los controladores. Los dispositivos Logitech siguen funcionando sin él."
                           },
    "WPFTweaksDisableNotifications":  {
                                          "Content":  "Notificaciones y calendario: desactivar",
                                          "Description":  "Desactiva todas las notificaciones del área de notificación, incluido el calendario."
                                      },
    "WPFTweaksBlockAdobeNet":  {
                                   "Content":  "Bloquear servidores de Adobe: activar",
                                   "Description":  "Reduce las interrupciones bloqueando de forma selectiva las conexiones a servidores de activación y telemetría de Adobe. Créditos: Ruddernation-Designs."
                               },
    "WPFTweaksRightClickMenu":  {
                                    "Content":  "Menú contextual clásico: restaurar",
                                    "Description":  "Recupera el menú contextual clásico del Explorador de archivos en lugar del menú simplificado de Windows 11."
                                },
    "WPFTweaksDiskCleanup":  {
                                 "Content":  "Liberador de espacio: ejecutar",
                                 "Description":  "Ejecuta el Liberador de espacio en la unidad C: y elimina archivos de actualizaciones antiguas de Windows."
                             },
    "WPFTweaksDeleteTempFiles":  {
                                     "Content":  "Archivos temporales: eliminar",
                                     "Description":  "Elimina el contenido de las carpetas TEMP."
                                 },
    "WPFTweaksIPv46":  {
                           "Content":  "IPv6: dar prioridad a IPv4",
                           "Description":  "Da prioridad a IPv4. Puede mejorar la latencia y la seguridad en redes privadas donde IPv6 no está configurado."
                       },
    "WPFTweaksTeredo":  {
                            "Content":  "Teredo: desactivar",
                            "Description":  "Desactiva Teredo, un mecanismo de túneles IPv6 que puede añadir latencia. Desactivarlo puede causar problemas con algunos juegos."
                        },
    "WPFTweaksDisableIPv6":  {
                                 "Content":  "IPv6: desactivar",
                                 "Description":  "Desactiva el protocolo IPv6."
                             },
    "WPFTweaksDisableBGapps":  {
                                   "Content":  "Aplicaciones en segundo plano: desactivar",
                                   "Description":  "Impide que las aplicaciones de Microsoft Store se ejecuten en segundo plano. En Windows 11, normalmente hay que configurarlas por separado."
                               },
    "WPFTweaksDeBloat":  {
                             "Content":  "Eliminar apps de Microsoft Store - NO RECOMENDADO",
                             "Description":  "Elimina para todos los usuarios una lista de aplicaciones de Microsoft Store usada por WinUtil y evita que se instalen automáticamente en cuentas nuevas. Incluye Minecraft Bedrock, Gaming Services, apps multimedia, de comunicación y algunas apps de terceros si están instaladas. No elimina absolutamente todas las apps: conserva Microsoft Store y los componentes esenciales. No tiene restauración automática; tendrás que reinstalar las aplicaciones y juegos por separado y podrías perder datos."
                         },
    "WPFTweaksDisableExplorerAutoDiscovery":  {
                                                  "Content":  "Detección de carpetas: desactivar",
                                                  "Description":  "Impide que el Explorador adivine el tipo de carpeta según sus archivos, lo que puede ralentizar la navegación. ¡Atención! También desactiva la agrupación de archivos."
                                              },
    "WPFToggleDetailedBSoD":  {
                                  "Content":  "Pantalla azul: información detallada",
                                  "Description":  "Muestra más información cuando se produce una pantalla azul de error (BSOD)."
                              },
    "WPFToggleBatteryPercentage":  {
                                       "Content":  "Porcentaje de batería en la bandeja",
                                       "Description":  "Muestra el porcentaje numérico junto al icono de batería en el área de notificación."
                                   },
    "WPFToggleDarkMode":  {
                              "Content":  "Tema oscuro de Windows",
                              "Description":  "Activa el modo oscuro del sistema y de las aplicaciones."
                          },
    "WPFToggleShowExt":  {
                             "Content":  "Extensiones de archivos visibles",
                             "Description":  "Muestra las extensiones de archivos en el Explorador (.exe, .png, etc.)."
                         },
    "WPFToggleHiddenFiles":  {
                                 "Content":  "Archivos ocultos visibles",
                                 "Description":  "Muestra los archivos ocultos en el Explorador."
                             },
    "WPFToggleVerboseLogon":  {
                                  "Content":  "Mensajes detallados de inicio de sesión",
                                  "Description":  "Muestra mensajes detallados durante el inicio y el apagado de Windows."
                              },
    "WPFToggleNewOutlook":  {
                                "Content":  "Nueva versión de Microsoft Outlook",
                                "Description":  "Configura Windows para utilizar la nueva aplicación Outlook."
                            },
    "WPFToggleScrollbars":  {
                                "Content":  "Barras de desplazamiento siempre visibles",
                                "Description":  "Al activarlo, las barras de desplazamiento permanecen visibles. Al desactivarlo, Windows las oculta automáticamente cuando no se usan."
                            },
    "WPFMultiplaneOverlay":  {
                                 "Content":  "Superposición multiplano (MPO)",
                                 "Description":  "La superposición multiplano compone varias capas de imagen y puede causar problemas con ciertas tarjetas gráficas. Los cambios se aplican de inmediato.",
                                 "ComboItems":  {
                                                    "Enabled":  "Activado",
                                                    "Disabled (Compatibility)":  "Desactivado (compatibilidad)",
                                                    "Fully Disabled":  "Completamente desactivado"
                                                },
                                 "ComboDescriptions":  {
                                                           "Enabled":  "Utiliza el comportamiento predeterminado de superposición de Windows.",
                                                           "Disabled (Compatibility)":  "Desactiva MPO mediante OverlayTestMode=5, un método de compatibilidad menos agresivo.",
                                                           "Fully Disabled":  "Desactiva MPO mediante OverlayTestMode=5 y DisableOverlays=1, un método más agresivo."
                                                       }
                             },
    "WPFToggleMouseAcceleration":  {
                                       "Content":  "Aceleración del mouse",
                                       "Description":  "Hace que el movimiento del cursor dependa de la velocidad a la que mueves físicamente el mouse."
                                   },
    "WPFToggleNumLock":  {
                             "Content":  "Bloq Num al iniciar",
                             "Description":  "Activa o desactiva la tecla Bloq Num cuando arranca el equipo."
                         },
    "WPFToggleWindowSnapping":  {
                                    "Content":  "Ajuste de ventanas",
                                    "Description":  "Activa o desactiva el ajuste automático de ventanas al arrastrarlas."
                                },
    "WPFToggleStandbyFix":  {
                                "Content":  "Conexión de red en suspensión S0",
                                "Description":  "Permite activar o desactivar la conexión de red durante la suspensión S0, un estado de bajo consumo usado en portátiles modernos."
                            },
    "WPFToggleS3Sleep":  {
                             "Content":  "Suspensión S3",
                             "Description":  "Alterna entre suspensión moderna y S3. En S3, se corta la alimentación de la CPU mientras se mantiene la memoria."
                         },
    "WPFToggleHideSettingsHome":  {
                                      "Content":  "Página Inicio de Configuración",
                                      "Description":  "Muestra u oculta la página Inicio de la aplicación Configuración de Windows."
                                  },
    "WPFToggleBingSearch":  {
                                "Content":  "Búsqueda web de Bing en Inicio",
                                "Description":  "Muestra u oculta resultados web de Bing en la búsqueda de Windows."
                            },
    "WPFToggleLoginBlur":  {
                               "Content":  "Desenfoque de la pantalla de inicio de sesión",
                               "Description":  "Activa o desactiva el efecto de desenfoque acrílico del fondo de inicio de sesión."
                           },
    "WPFToggleDisableLockscreen":  {
                                       "Content":  "Pantalla de bloqueo: desactivar",
                                       "Description":  "Omite la pantalla de bloqueo y abre directamente la pantalla de inicio de sesión al arrancar o reactivar Windows."
                                   },
    "WPFToggleStartMenuRecommendations":  {
                                              "Content":  "Recomendaciones del menú Inicio",
                                              "Description":  "Muestra u oculta las recomendaciones del menú Inicio. Atención: al desactivarlas también se desactiva el contenido destacado de Windows Spotlight en la pantalla de bloqueo."
                                          },
    "WPFToggleStickyKeys":  {
                                "Content":  "Teclas especiales",
                                "Description":  "Activa o desactiva las teclas especiales, que pueden activarse al pulsar Mayús varias veces seguidas."
                            },
    "WPFToggleTaskbarAlignment":  {
                                      "Content":  "Iconos centrados en la barra de tareas",
                                      "Description":  "Cambia la alineación de los iconos de la barra de tareas entre izquierda y centro."
                                  },
    "WPFToggleTaskbarSearch":  {
                                   "Content":  "Icono de búsqueda en la barra de tareas",
                                   "Description":  "Muestra u oculta el botón de búsqueda de la barra de tareas."
                               },
    "WPFToggleTaskView":  {
                              "Content":  "Icono Vista de tareas",
                              "Description":  "Muestra u oculta el botón Vista de tareas de la barra de tareas."
                          },
    "WPFToggleGameMode":  {
                              "Content":  "Modo Juego",
                              "Description":  "Activa o desactiva el Modo Juego, que da prioridad al rendimiento de los juegos al asignar recursos del sistema."
                          },
    "WPFToggleGameDVR":  {
                             "Content":  "Grabación en segundo plano (Game DVR)",
                             "Description":  "Activa o desactiva la captura en segundo plano de Xbox Game Bar (Grabar lo que ha sucedido). Al desactivarla se evita codificar vídeo continuamente mientras juegas. No elimina las capturas de pantalla ni la grabación manual."
                         },
    "WPFToggleHAGS":  {
                          "Content":  "Programación de GPU acelerada por hardware",
                          "Description":  "Activa o desactiva que la tarjeta gráfica gestione su propia programación (HwSchMode). Requiere GPU y driver WDDM 2.7 o superior y reiniciar. El resultado depende de la GPU y del juego; Windows lo ignora en hardware no compatible."
                      },
    "WPFToggleGamingMultimediaProfile":  {
                                             "Content":  "Perfil multimedia para juegos",
                                             "Description":  "Activa o desactiva el perfil de sistema de MMCSS: reserva un 10 % de CPU para tareas en segundo plano en lugar del 20 % (SystemResponsiveness) y desactiva la limitación de red multimedia (NetworkThrottlingIndex 0xFFFFFFFF). Al desactivarlo se restauran los valores de Windows, 20 y 10. No garantiza más FPS."
                                         },
    "WPFToggleFastStartup":  {
                                 "Content":  "Inicio rápido",
                                 "Description":  "Activa o desactiva el Inicio rápido (HiberbootEnabled). Al desactivarlo, Apagar realiza un apagado completo y los drivers y el kernel arrancan limpios; el arranque puede tardar unos segundos más. No tiene efecto si la hibernación está desactivada."
                             },
    "WPFToggleLongPaths":  {
                               "Content":  "Rutas de archivos largas: activar",
                               "Description":  "Activa o desactiva la compatibilidad con rutas de archivos de más de 260 caracteres en el Explorador."
                           },
    "WPFchangedns":  {
                         "Content":  "DNS: seleccionar servidor:",
                         "Description":  "Selecciona la configuración o el proveedor DNS, incluidos servidores con filtros opcionales de malware, contenido para adultos, anuncios o rastreadores.",
                         "ComboItems":  {
                                            "Default":  "Predeterminado",
                                            "DHCP":  "DHCP",
                                            "Fastest":  "Más rápido",
                                            "Google":  "Google",
                                            "Cloudflare":  "Cloudflare",
                                            "Cloudflare_Malware":  "Cloudflare (malware)",
                                            "Cloudflare_Malware_Adult":  "Cloudflare (malware y adultos)",
                                            "Open_DNS":  "OpenDNS",
                                            "Quad9":  "Quad9",
                                            "AdGuard_Ads_Trackers":  "AdGuard (anuncios y rastreadores)",
                                            "AdGuard_Ads_Trackers_Malware_Adult":  "AdGuard (anuncios, rastreadores, malware y adultos)"
                                        }
                     },
    "WPFAddUltPerf":  {
                          "Content":  "Plan Máximo rendimiento: activar",
                          "Description":  "Activa el plan de energía Máximo rendimiento. Está pensado para equipos de escritorio; puede aumentar el consumo energético y no se recomienda en portátiles."
                      },
    "WPFRemoveUltPerf":  {
                             "Content":  "Plan Máximo rendimiento: desactivar",
                             "Description":  "Elimina el plan de energía Máximo rendimiento para dejar de utilizarlo."
                         },
    "Categories":  {
                       "Essential Tweaks":  "Ajustes esenciales",
                       "Advanced Tweaks - CAUTION":  "Ajustes avanzados - PRECAUCIÓN",
                       "Customize Preferences":  "Personalizar preferencias",
                       "Performance Plans - NOT FOR LAPTOPS":  "Planes de energía - NO PARA PORTÁTILES"
                   }
}
'@ | ConvertFrom-Json
$sync.configs.guided = @'
{
    "Questions":  [
                      {
                          "Id":  "RestorePoint",
                          "Section":  "basic",
                          "Category":  {
                                           "en":  "Before you start",
                                           "es":  "Antes de empezar"
                                       },
                          "Title":  {
                                        "en":  "Create a restore point before applying the changes?",
                                        "es":  "¿Crear un punto de restauración antes de aplicar los cambios?"
                                    },
                          "Body":  {
                                       "en":  "If something does not work as expected, you can roll Windows back to today\u0027s state from System Restore.",
                                       "es":  "Si algo no funciona como esperabas, podrás volver Windows al estado de hoy desde Restaurar sistema."
                                   },
                          "Details":  {
                                          "en":  [
                                                     "Turns System Restore on for the system drive when it has no restore points yet.",
                                                     "Removes the Windows limit of one restore point every 24 hours.",
                                                     "The point is created before any other guided change."
                                                 ],
                                          "es":  [
                                                     "Activa Restaurar sistema en la unidad del sistema si todavía no tiene puntos de restauración.",
                                                     "Quita el límite de Windows de un punto de restauración cada 24 horas.",
                                                     "El punto se crea antes que cualquier otro cambio del modo guiado."
                                                 ]
                                      },
                          "Note":  {
                                       "en":  "To roll back later, search Start for \"Create a restore point\" and open System Restore.",
                                       "es":  "Para volver atrás, busca \"Crear un punto de restauración\" en Inicio y abre Restaurar sistema."
                                   },
                          "Summary":  {
                                          "en":  "Create a restore point",
                                          "es":  "Crear punto de restauración"
                                      },
                          "YesLabel":  {
                                           "en":  "Yes, create it",
                                           "es":  "Sí, crearlo"
                                       },
                          "Recommended":  true,
                          "Reversible":  true,
                          "Actions":  [
                                          {
                                              "Key":  "WPFTweaksRestorePoint"
                                          }
                                      ]
                      },
                      {
                          "Id":  "Telemetry",
                          "Section":  "basic",
                          "Category":  {
                                           "en":  "Privacy",
                                           "es":  "Privacidad"
                                       },
                          "Title":  {
                                        "en":  "Cut Windows telemetry and promotions?",
                                        "es":  "¿Cortar la telemetría y las promociones de Windows?"
                                    },
                          "Body":  {
                                       "en":  "Windows sends usage data to Microsoft and installs or suggests apps on its own. Each option is separate: clear the ones you want to keep.",
                                       "es":  "Windows envía datos de uso a Microsoft e instala o sugiere apps por su cuenta. Cada opción es independiente: desmarca las que quieras conservar."
                                   },
                          "Summary":  {
                                          "en":  "Privacy",
                                          "es":  "Privacidad"
                                      },
                          "YesLabel":  {
                                           "en":  "Next",
                                           "es":  "Siguiente"
                                       },
                          "NoLabel":  {
                                          "en":  "None",
                                          "es":  "Ninguna"
                                      },
                          "Recommended":  true,
                          "Reversible":  true,
                          "Options":  [
                                          {
                                              "Id":  "Telemetry",
                                              "Default":  true,
                                              "Label":  {
                                                            "en":  "Turn off telemetry and promoted apps",
                                                            "es":  "Desactivar telemetría y apps promocionadas"
                                                        },
                                              "Detail":  {
                                                             "en":  "Diagnostic data at the minimum level, no advertising ID, no typing and voice data collection and no feedback prompts. Disables DiagTrack and error reporting, stops automatic Defender sample submission and stops Windows from installing promoted apps.",
                                                             "es":  "Datos de diagnóstico al mínimo, sin ID de publicidad, sin recopilar lo que escribes o dictas y sin encuestas de opinión. Deshabilita DiagTrack y el informe de errores, frena el envío automático de muestras de Defender y evita que Windows instale apps promocionadas."
                                                         },
                                              "Actions":  [
                                                              {
                                                                  "Key":  "WPFTweaksTelemetry"
                                                              },
                                                              {
                                                                  "Key":  "WPFTweaksConsumerFeatures"
                                                              }
                                                          ]
                                          },
                                          {
                                              "Id":  "TelemetryTasks",
                                              "Default":  true,
                                              "Label":  {
                                                            "en":  "Turn off telemetry scheduled tasks",
                                                            "es":  "Desactivar tareas programadas de telemetría"
                                                        },
                                              "Detail":  {
                                                             "en":  "Compatibility Appraiser, ProgramDataUpdater, the Customer Experience Improvement Program tasks, UsageDataReporting and SustainabilityTelemetry. Their state is saved so they can be restored.",
                                                             "es":  "Compatibility Appraiser, ProgramDataUpdater, las tareas del Programa de mejora de la experiencia del cliente, UsageDataReporting y SustainabilityTelemetry. Se guarda su estado para poder restaurarlas."
                                                         },
                                              "Actions":  [
                                                              {
                                                                  "Key":  "WPFTaskGroupTelemetry",
                                                                  "Members":  [
                                                                                  "WPFToggleTaskCompatibilityAppraiser",
                                                                                  "WPFToggleTaskProgramDataUpdater",
                                                                                  "WPFToggleTaskConsolidator",
                                                                                  "WPFToggleTaskUsbCeip",
                                                                                  "WPFToggleTaskKernelCeip",
                                                                                  "WPFToggleTaskCompatibilityAppraiserExp",
                                                                                  "WPFToggleTaskUsageDataReporting",
                                                                                  "WPFToggleTaskSustainabilityTelemetry"
                                                                              ]
                                                              }
                                                          ]
                                          },
                                          {
                                              "Id":  "DeliveryOptimization",
                                              "Default":  true,
                                              "Label":  {
                                                            "en":  "Turn off Delivery Optimization",
                                                            "es":  "Desactivar Optimización de distribución"
                                                        },
                                              "Detail":  {
                                                             "en":  "Windows stops uploading updates to other PCs on the Internet or your network. Updates still download normally.",
                                                             "es":  "Windows deja de subir actualizaciones a otras PCs de Internet o de tu red. Las actualizaciones se siguen descargando normal."
                                                         },
                                              "Actions":  [
                                                              {
                                                                  "Key":  "WPFTweaksDeliveryOptimization"
                                                              }
                                                          ]
                                          },
                                          {
                                              "Id":  "VendorSoftware",
                                              "Default":  true,
                                              "Label":  {
                                                            "en":  "Block vendor software installs",
                                                            "es":  "Bloquear software de fabricantes"
                                                        },
                                              "Detail":  {
                                                             "en":  "Blocks programs the PC vendor runs from the firmware (WPBT), companion apps Windows downloads when you plug in devices and Logi Download Assistant. Devices keep working. If you use the vendor\u0027s anti-theft software, clear this option.",
                                                             "es":  "Bloquea programas que el fabricante ejecuta desde el firmware (WPBT), las apps que Windows descarga al conectar dispositivos y Logi Download Assistant. Los dispositivos siguen funcionando. Si usas el antirrobo del fabricante, desmarca esta opción."
                                                         },
                                              "Actions":  [
                                                              {
                                                                  "Key":  "WPFTweaksWPBT"
                                                              },
                                                              {
                                                                  "Key":  "WPFTweaksPreventDeviceMetadataFromNetwork"
                                                              },
                                                              {
                                                                  "Key":  "WPFTweaksLogiBlock"
                                                              }
                                                          ]
                                          },
                                          {
                                              "Id":  "StartRecommendations",
                                              "Default":  true,
                                              "Label":  {
                                                            "en":  "Hide Start recommendations",
                                                            "es":  "Ocultar recomendaciones de Inicio"
                                                        },
                                              "Detail":  {
                                                             "en":  "Hides the Recommended section of Start and suggested Store apps when you search. It also turns off Windows Spotlight on the lock screen. Explorer restarts once.",
                                                             "es":  "Oculta la sección Recomendado del menú Inicio y las apps sugeridas de la Store al buscar. También apaga Windows Spotlight en la pantalla de bloqueo. El Explorador se reinicia una vez."
                                                         },
                                              "Actions":  [
                                                              {
                                                                  "Key":  "WPFToggleStartMenuRecommendations",
                                                                  "State":  false
                                                              },
                                                              {
                                                                  "Key":  "WPFTweaksDisableStoreSearch"
                                                              }
                                                          ]
                                          }
                                      ]
                      },
                      {
                          "Id":  "BackgroundApps",
                          "Section":  "basic",
                          "Category":  {
                                           "en":  "Performance",
                                           "es":  "Rendimiento"
                                       },
                          "Title":  {
                                        "en":  "Stop Store apps from running in the background?",
                                        "es":  "¿Impedir que las apps de la Store funcionen en segundo plano?"
                                    },
                          "Body":  {
                                       "en":  "Fewer processes and less memory use while you play. Some apps may send notifications only while they are open.",
                                       "es":  "Menos procesos y memoria en uso mientras juegas. Algunas apps pueden avisar solo mientras están abiertas."
                                   },
                          "Details":  {
                                          "en":  [
                                                     "Blocks background execution of every Store app for your user.",
                                                     "Classic programs such as Steam, Discord or driver tools are not affected.",
                                                     "Apps such as Mail, Phone Link or Xbox stop syncing and notifying while closed."
                                                 ],
                                          "es":  [
                                                     "Bloquea para tu usuario la ejecución en segundo plano de todas las apps de la Store.",
                                                     "No afecta a programas clásicos como Steam, Discord o las herramientas de los drivers.",
                                                     "Apps como Correo, Vincular teléfono o Xbox dejan de sincronizar y avisar mientras están cerradas."
                                                 ]
                                      },
                          "Summary":  {
                                          "en":  "Turn off background Store apps",
                                          "es":  "Desactivar apps de la Store en segundo plano"
                                      },
                          "Recommended":  true,
                          "Reversible":  true,
                          "Actions":  [
                                          {
                                              "Key":  "WPFTweaksDisableBGapps"
                                          }
                                      ]
                      },
                      {
                          "Id":  "VisualEffects",
                          "Section":  "basic",
                          "Category":  {
                                           "en":  "Performance",
                                           "es":  "Rendimiento"
                                       },
                          "Title":  {
                                        "en":  "Set visual effects for best performance?",
                                        "es":  "¿Ajustar los efectos visuales para el máximo rendimiento?"
                                    },
                          "Body":  {
                                       "en":  "Removes animations, shadows and transparency from windows and menus. On modest PCs Windows feels faster; on powerful PCs the difference is small.",
                                       "es":  "Quita animaciones, sombras y transparencias de ventanas y menús. En PCs modestas Windows se siente más rápido; en PCs potentes la diferencia es pequeña."
                                   },
                          "Details":  {
                                          "en":  [
                                                     "No animations when minimizing and maximizing windows or on the taskbar.",
                                                     "Windows show only their outline while you drag them.",
                                                     "No shadows or translucent selection in Explorer, and no Aero Peek.",
                                                     "Menus open faster (200 ms instead of 400 ms) and key repeat starts sooner.",
                                                     "Hides Search, Task View and Chat from the taskbar."
                                                 ],
                                          "es":  [
                                                     "Sin animaciones al minimizar y maximizar ventanas ni en la barra de tareas.",
                                                     "Las ventanas muestran solo su contorno mientras las arrastras.",
                                                     "Sin sombras ni selección translúcida en el Explorador, y sin Aero Peek.",
                                                     "Los menús abren más rápido (200 ms en lugar de 400 ms) y la repetición de teclas empieza antes.",
                                                     "Oculta Buscar, Vista de tareas y Chat de la barra de tareas."
                                                 ]
                                      },
                          "Note":  {
                                       "en":  "Some effects change only after you sign out or restart.",
                                       "es":  "Algunos efectos cambian recién al cerrar sesión o reiniciar."
                                   },
                          "Summary":  {
                                          "en":  "Visual effects for best performance",
                                          "es":  "Efectos visuales para máximo rendimiento"
                                      },
                          "Recommended":  false,
                          "Reversible":  true,
                          "Actions":  [
                                          {
                                              "Key":  "WPFTweaksDisplay"
                                          }
                                      ]
                      },
                      {
                          "Id":  "Services",
                          "Section":  "basic",
                          "Category":  {
                                           "en":  "Services",
                                           "es":  "Servicios"
                                       },
                          "Title":  {
                                        "en":  "Which services should we adjust?",
                                        "es":  "¿Qué servicios ajustamos?"
                                    },
                          "Body":  {
                                       "en":  "Windows starts many services that most PCs never use. Each group is separate: switch off the ones you want to leave as they are.",
                                       "es":  "Windows arranca muchos servicios que la mayoría de las PCs no usa. Cada grupo es independiente: apaga los que quieras dejar como están."
                                   },
                          "Note":  {
                                       "en":  "Services you changed yourself are left alone, and only services installed on this PC are touched. Everything can be undone from advanced mode.",
                                       "es":  "Los servicios que cambiaste tú se dejan como están y solo se tocan los que están instalados en esta PC. Todo se puede deshacer desde el modo avanzado."
                                   },
                          "Summary":  {
                                          "en":  "Services",
                                          "es":  "Servicios"
                                      },
                          "YesLabel":  {
                                           "en":  "Next",
                                           "es":  "Siguiente"
                                       },
                          "NoLabel":  {
                                          "en":  "None",
                                          "es":  "Ninguno"
                                      },
                          "OptionStyle":  "Toggle",
                          "Recommended":  true,
                          "Reversible":  true,
                          "Options":  [
                                          {
                                              "Id":  "ServicesManual",
                                              "Default":  true,
                                              "Label":  {
                                                            "en":  "Windows services to Manual",
                                                            "es":  "Servicios de Windows en Manual"
                                                        },
                                              "Detail":  {
                                                             "en":  "MapsBroker and StorSvc go to Manual; Offline Files (CscService), telemetry (DiagTrack) and Internet Connection Sharing (SharedAccess) are disabled. Fewer svchost.exe processes, based on your RAM. If you share this PC\u0027s Internet connection, switch this off.",
                                                             "es":  "MapsBroker y StorSvc pasan a Manual; Archivos sin conexión (CscService), telemetría (DiagTrack) y Conexión compartida a Internet (SharedAccess) quedan deshabilitados. Menos procesos svchost.exe según tu RAM. Si compartes la conexión a Internet de esta PC, apágalo."
                                                         },
                                              "Actions":  [
                                                              {
                                                                  "Key":  "WPFTweaksServices"
                                                              }
                                                          ]
                                          },
                                          {
                                              "Id":  "DiagnosticServices",
                                              "Default":  true,
                                              "Label":  {
                                                            "en":  "Disable diagnostic services",
                                                            "es":  "Desactivar servicios de diagnóstico"
                                                        },
                                              "Detail":  {
                                                             "en":  "Diagnostic hosts (WdiSystemHost, WdiServiceHost), Diagnostic Policy Service (DPS), DiagTrack, Windows Error Reporting (WerSvc) and the Diagnostics Hub Collector. Windows troubleshooters stop working.",
                                                             "es":  "Hosts de diagnóstico (WdiSystemHost, WdiServiceHost), Servicio de directivas de diagnóstico (DPS), DiagTrack, Informe de errores (WerSvc) y Recopilador de diagnósticos. Los solucionadores de problemas de Windows dejan de funcionar."
                                                         },
                                              "Actions":  [
                                                              {
                                                                  "Key":  "WPFServiceGroupDiagnostics"
                                                              }
                                                          ]
                                          },
                                          {
                                              "Id":  "UselessServices",
                                              "Default":  true,
                                              "Label":  {
                                                            "en":  "Disable unneeded services",
                                                            "es":  "Desactivar servicios innecesarios"
                                                        },
                                              "Detail":  {
                                                             "en":  "AutoPlay (ShellHWDetection), Windows Media Player sharing, Windows Insider, Retail Demo, WPF Font Cache, Net.TCP Port Sharing, Windows Health and WAP Push. If a company manages this PC (Intune/MDM), switch this off.",
                                                             "es":  "Reproducción automática (ShellHWDetection), uso compartido del Reproductor de Windows Media, Windows Insider, Demo de tienda, caché de fuentes WPF, Net.TCP, Windows Health y mensajes push WAP. Si tu PC la administra una empresa (Intune/MDM), apágalo."
                                                         },
                                              "Actions":  [
                                                              {
                                                                  "Key":  "WPFServiceGroupUseless"
                                                              }
                                                          ]
                                          }
                                      ]
                      },
                      {
                          "Id":  "WidgetsAI",
                          "Section":  "basic",
                          "Category":  {
                                           "en":  "Apps",
                                           "es":  "Apps"
                                       },
                          "Title":  {
                                        "en":  "Remove Widgets and Windows AI features (Copilot)?",
                                        "es":  "¿Quitar los Widgets y las funciones de IA de Windows (Copilot)?"
                                    },
                          "Body":  {
                                       "en":  "Removes the taskbar Widgets panel and the Copilot and AI packages, which run in the background.",
                                       "es":  "Quita el panel de Widgets de la barra de tareas y los paquetes de Copilot e IA, que funcionan en segundo plano."
                                   },
                          "Details":  {
                                          "en":  [
                                                     "Removes the Widgets panel and its packages, then restarts Explorer.",
                                                     "Removes Copilot and the Microsoft 365 (Office Hub) app.",
                                                     "Turns off Recall and the Windows AI service (WSAIFabricSvc).",
                                                     "Hides the AI components page in Settings and turns off AI features in Notepad."
                                                 ],
                                          "es":  [
                                                     "Quita el panel de Widgets y sus paquetes, y reinicia el Explorador.",
                                                     "Quita Copilot y la app Microsoft 365 (Office Hub).",
                                                     "Desactiva Recall y el servicio de IA de Windows (WSAIFabricSvc).",
                                                     "Oculta la página de componentes de IA en Configuración y apaga la IA del Bloc de notas."
                                                 ]
                                      },
                          "Note":  {
                                       "en":  "Removed packages are not restored by Undo. You would have to reinstall them from the Microsoft Store.",
                                       "es":  "Deshacer no reinstala los paquetes quitados. Tendrías que volver a instalarlos desde la Microsoft Store."
                                   },
                          "Summary":  {
                                          "en":  "Remove Widgets and Windows AI",
                                          "es":  "Quitar Widgets e IA de Windows"
                                      },
                          "Recommended":  true,
                          "Reversible":  false,
                          "Actions":  [
                                          {
                                              "Key":  "WPFTweaksWidget"
                                          },
                                          {
                                              "Key":  "WPFTweaksWindowsAI"
                                          }
                                      ]
                      },
                      {
                          "Id":  "Explorer",
                          "Section":  "basic",
                          "Category":  {
                                           "en":  "Explorer and Windows 11",
                                           "es":  "Explorador y Windows 11"
                                       },
                          "Title":  {
                                        "en":  "Make Windows 11 more comfortable to use?",
                                        "es":  "¿Hacer Windows 11 más cómodo de usar?"
                                    },
                          "Body":  {
                                       "en":  "These changes are applied together. Clear the ones you do not want.",
                                       "es":  "Aplicamos estos cambios juntos. Desmarca los que no quieras."
                                   },
                          "Summary":  {
                                          "en":  "Explorer and Windows 11",
                                          "es":  "Explorador y Windows 11"
                                      },
                          "YesLabel":  {
                                           "en":  "Next",
                                           "es":  "Siguiente"
                                       },
                          "NoLabel":  {
                                          "en":  "None",
                                          "es":  "Ninguno"
                                      },
                          "Recommended":  true,
                          "Reversible":  true,
                          "Options":  [
                                          {
                                              "Id":  "ClassicContextMenu",
                                              "Default":  true,
                                              "Label":  {
                                                            "en":  "Classic context menu",
                                                            "es":  "Menú contextual clásico"
                                                        },
                                              "Detail":  {
                                                             "en":  "Right-click shows every option without going through \"Show more options\". Explorer restarts once.",
                                                             "es":  "El clic derecho muestra todas las opciones sin pasar por \"Mostrar más opciones\". El Explorador se reinicia una vez."
                                                         },
                                              "Actions":  [
                                                              {
                                                                  "Key":  "WPFTweaksRightClickMenu"
                                                              }
                                                          ]
                                          },
                                          {
                                              "Id":  "NoBingSearch",
                                              "Default":  true,
                                              "Label":  {
                                                            "en":  "Remove Bing from Start search",
                                                            "es":  "Quitar Bing de la búsqueda de Inicio"
                                                        },
                                              "Detail":  {
                                                             "en":  "Start searches only your PC, without web results.",
                                                             "es":  "Inicio busca solo en tu PC, sin resultados web."
                                                         },
                                              "Actions":  [
                                                              {
                                                                  "Key":  "WPFToggleBingSearch",
                                                                  "State":  false
                                                              }
                                                          ]
                                          },
                                          {
                                              "Id":  "LongPaths",
                                              "Default":  true,
                                              "Label":  {
                                                            "en":  "Enable long file paths",
                                                            "es":  "Activar rutas de archivos largas"
                                                        },
                                              "Detail":  {
                                                             "en":  "Allows paths longer than 260 characters. Useful for modded games and large projects.",
                                                             "es":  "Permite rutas de más de 260 caracteres. Útil para juegos con mods y proyectos grandes."
                                                         },
                                              "Actions":  [
                                                              {
                                                                  "Key":  "WPFToggleLongPaths",
                                                                  "State":  true
                                                              }
                                                          ]
                                          },
                                          {
                                              "Id":  "HiddenFiles",
                                              "Default":  true,
                                              "Label":  {
                                                            "en":  "Show hidden files",
                                                            "es":  "Mostrar archivos ocultos"
                                                        },
                                              "Detail":  {
                                                             "en":  "Folders such as AppData become visible in File Explorer.",
                                                             "es":  "Ves carpetas como AppData en el Explorador."
                                                         },
                                              "Actions":  [
                                                              {
                                                                  "Key":  "WPFToggleHiddenFiles",
                                                                  "State":  true
                                                              }
                                                          ]
                                          },
                                          {
                                              "Id":  "EndTask",
                                              "Default":  true,
                                              "Label":  {
                                                            "en":  "End task from the taskbar",
                                                            "es":  "Finalizar tarea desde la barra de tareas"
                                                        },
                                              "Detail":  {
                                                             "en":  "Right-clicking an open app in the taskbar shows \"End task\", without opening Task Manager.",
                                                             "es":  "Al hacer clic derecho en una app abierta de la barra de tareas aparece \"Finalizar tarea\", sin abrir el Administrador de tareas."
                                                         },
                                              "Actions":  [
                                                              {
                                                                  "Key":  "WPFTweaksEndTaskOnTaskbar"
                                                              }
                                                          ]
                                          }
                                      ]
                      },
                      {
                          "Id":  "GameDVR",
                          "Section":  "basic",
                          "Category":  {
                                           "en":  "Gaming",
                                           "es":  "Juegos"
                                       },
                          "Title":  {
                                        "en":  "Turn off background recording (Game DVR)?",
                                        "es":  "¿Desactivar la grabación en segundo plano (Game DVR)?"
                                    },
                          "Body":  {
                                       "en":  "Windows can keep recording the last minutes of play all the time. If you do not use it, turning it off frees GPU and disk while you play.",
                                       "es":  "Windows puede grabar los últimos minutos de juego todo el tiempo. Si no lo usas, desactivarlo libera GPU y disco mientras juegas."
                                   },
                          "Details":  {
                                          "en":  [
                                                     "Turns off \"Record what happened\" background capture in Xbox Game Bar.",
                                                     "Turns off Game DVR in the Windows game settings.",
                                                     "Xbox Game Bar itself stays installed."
                                                 ],
                                          "es":  [
                                                     "Apaga la captura en segundo plano (\"Grabar lo que pasó\") de Xbox Game Bar.",
                                                     "Apaga Game DVR en la configuración de juegos de Windows.",
                                                     "Xbox Game Bar sigue instalada."
                                                 ]
                                      },
                          "Note":  {
                                       "en":  "Screenshots and manual recording keep working.",
                                       "es":  "Las capturas de pantalla y la grabación manual siguen funcionando."
                                   },
                          "Summary":  {
                                          "en":  "Turn off Game DVR",
                                          "es":  "Desactivar Game DVR"
                                      },
                          "YesLabel":  {
                                           "en":  "Yes, turn it off",
                                           "es":  "Sí, desactivar"
                                       },
                          "NoLabel":  {
                                          "en":  "No, I use it",
                                          "es":  "No, la uso"
                                      },
                          "Recommended":  true,
                          "Reversible":  true,
                          "Actions":  [
                                          {
                                              "Key":  "WPFToggleGameDVR",
                                              "State":  false
                                          }
                                      ]
                      },
                      {
                          "Id":  "MultimediaProfile",
                          "Section":  "basic",
                          "Category":  {
                                           "en":  "Gaming",
                                           "es":  "Juegos"
                                       },
                          "Title":  {
                                        "en":  "Use the multimedia profile for gaming?",
                                        "es":  "¿Usar el perfil multimedia para juegos?"
                                    },
                          "Body":  {
                                       "en":  "Windows reserves 10% of the CPU for background tasks instead of 20% and stops throttling network traffic during multimedia playback.",
                                       "es":  "Windows reserva un 10 % de CPU para tareas en segundo plano en lugar del 20 % y deja de limitar la red durante la reproducción multimedia."
                                   },
                          "Details":  {
                                          "en":  [
                                                     "SystemResponsiveness: 10 % reserved for background tasks (Windows uses 20 %).",
                                                     "NetworkThrottlingIndex: off. Windows normally limits network packets while audio or video plays.",
                                                     "It is a system-wide setting; no game file is changed."
                                                 ],
                                          "es":  [
                                                     "SystemResponsiveness: 10 % reservado para tareas en segundo plano (Windows usa 20 %).",
                                                     "NetworkThrottlingIndex: desactivado. Windows normalmente limita los paquetes de red mientras se reproduce audio o video.",
                                                     "Es un ajuste de todo el sistema; no se modifica ningún archivo de juegos."
                                                 ]
                                      },
                          "Note":  {
                                       "en":  "FPS gains are not guaranteed.",
                                       "es":  "No garantiza más FPS."
                                   },
                          "Summary":  {
                                          "en":  "Multimedia profile for gaming",
                                          "es":  "Perfil multimedia para juegos"
                                      },
                          "Recommended":  true,
                          "Reversible":  true,
                          "Actions":  [
                                          {
                                              "Key":  "WPFToggleGamingMultimediaProfile",
                                              "State":  true
                                          }
                                      ]
                      },
                      {
                          "Id":  "PowerPlan",
                          "Section":  "basic",
                          "Category":  {
                                           "en":  "Power",
                                           "es":  "Energía"
                                       },
                          "Title":  {
                                        "en":  "Turn on the Ultimate Performance power plan?",
                                        "es":  "¿Activar el plan de energía Máximo rendimiento?"
                                    },
                          "Body":  {
                                       "en":  "Windows stops lowering the processor speed and switching off hardware to save power, so the PC responds faster. It is meant for desktop PCs.",
                                       "es":  "Windows deja de bajar la velocidad del procesador y de apagar partes del hardware para ahorrar energía, así la PC responde más rápido. Está pensado para PCs de escritorio."
                                   },
                          "Details":  {
                                          "en":  [
                                                     "Adds a copy of the Ultimate Performance plan and makes it the active plan.",
                                                     "The processor keeps a high minimum speed and disks do not spin down.",
                                                     "It is applied before the USB and PCIe power question, so that change lands on the new plan.",
                                                     "To go back, choose another plan in Control Panel \u003e Power Options."
                                                 ],
                                          "es":  [
                                                     "Agrega una copia del plan Máximo rendimiento y la deja como plan activo.",
                                                     "El procesador mantiene una velocidad mínima alta y los discos no se apagan.",
                                                     "Se aplica antes que el ahorro de energía de USB y PCIe, así ese cambio queda en el plan nuevo.",
                                                     "Para volver, elige otro plan en Panel de control \u003e Opciones de energía."
                                                 ]
                                      },
                          "Note":  {
                                       "en":  "Undo from advanced mode restores the default Windows power plans and deletes custom plans.",
                                       "es":  "Deshacer desde el modo avanzado restablece los planes de energía de Windows y borra los planes personalizados."
                                   },
                          "Summary":  {
                                          "en":  "Ultimate Performance power plan",
                                          "es":  "Plan de energía Máximo rendimiento"
                                      },
                          "YesLabel":  {
                                           "en":  "Yes, turn on",
                                           "es":  "Sí, activar"
                                       },
                          "Advice":  "PowerPlan",
                          "Recommended":  false,
                          "Reversible":  true,
                          "Actions":  [
                                          {
                                              "Key":  "WPFAddUltPerf"
                                          }
                                      ]
                      },
                      {
                          "Id":  "DevicePowerSaving",
                          "Section":  "basic",
                          "Category":  {
                                           "en":  "Gaming",
                                           "es":  "Juegos"
                                       },
                          "Title":  {
                                        "en":  "Turn off USB and PCIe power saving?",
                                        "es":  "¿Desactivar el ahorro de energía de USB y PCIe?"
                                    },
                          "Body":  {
                                       "en":  "Can reduce mouse, controller or USB audio dropouts. Only applies while the PC is plugged in, in the active power plan.",
                                       "es":  "Puede reducir cortes del mouse, el mando o el audio USB. Solo se aplica con el equipo enchufado, en el plan de energía activo."
                                   },
                          "Details":  {
                                          "en":  [
                                                     "USB selective suspend: off while plugged in.",
                                                     "PCI Express Link State Power Management: off while plugged in.",
                                                     "Battery settings are not changed.",
                                                     "The previous values are saved so Undo can restore them."
                                                 ],
                                          "es":  [
                                                     "Suspensión selectiva de USB: desactivada con el equipo enchufado.",
                                                     "Administración de energía del estado de vínculo PCI Express: desactivada con el equipo enchufado.",
                                                     "La configuración con batería no se toca.",
                                                     "Se guardan los valores anteriores para que Deshacer los restaure."
                                                 ]
                                      },
                          "Note":  {
                                       "en":  "Power use at idle may increase slightly.",
                                       "es":  "El consumo en reposo puede subir un poco."
                                   },
                          "Summary":  {
                                          "en":  "Turn off USB and PCIe power saving",
                                          "es":  "Desactivar ahorro de USB y PCIe"
                                      },
                          "Recommended":  true,
                          "Reversible":  true,
                          "Actions":  [
                                          {
                                              "Key":  "WPFTweaksDisableDevicePowerSaving"
                                          }
                                      ]
                      },
                      {
                          "Id":  "HAGS",
                          "Section":  "basic",
                          "Category":  {
                                           "en":  "Gaming",
                                           "es":  "Juegos"
                                       },
                          "Title":  {
                                        "en":  "Turn on hardware-accelerated GPU scheduling (HAGS)?",
                                        "es":  "¿Activar la programación de GPU acelerada por hardware (HAGS)?"
                                    },
                          "Body":  {
                                       "en":  "The graphics card manages its own work queue. It needs a recent GPU and driver; Windows ignores it on unsupported hardware.",
                                       "es":  "La tarjeta gráfica gestiona su propia cola de trabajo. Requiere GPU y driver recientes; Windows lo ignora en hardware no compatible."
                                   },
                          "Details":  {
                                          "en":  [
                                                     "Same switch as Settings \u003e Display \u003e Graphics \u003e Hardware-accelerated GPU scheduling.",
                                                     "Writes HwSchMode = 2 in the graphics driver settings.",
                                                     "It takes effect after restarting."
                                                 ],
                                          "es":  [
                                                     "Es el mismo interruptor de Configuración \u003e Pantalla \u003e Gráficos \u003e Programación de GPU acelerada por hardware.",
                                                     "Escribe HwSchMode = 2 en la configuración de los drivers gráficos.",
                                                     "Se activa después de reiniciar."
                                                 ]
                                      },
                          "Note":  {
                                       "en":  "Results depend on the GPU and the game.",
                                       "es":  "El resultado depende de la GPU y del juego."
                                   },
                          "Summary":  {
                                          "en":  "Hardware-accelerated GPU scheduling",
                                          "es":  "Programación de GPU acelerada (HAGS)"
                                      },
                          "Recommended":  true,
                          "Reversible":  true,
                          "Reboot":  true,
                          "Actions":  [
                                          {
                                              "Key":  "WPFToggleHAGS",
                                              "State":  true
                                          }
                                      ]
                      },
                      {
                          "Id":  "TempFiles",
                          "Section":  "basic",
                          "Category":  {
                                           "en":  "Cleanup",
                                           "es":  "Limpieza"
                                       },
                          "Title":  {
                                        "en":  "Delete temporary files?",
                                        "es":  "¿Borrar los archivos temporales?"
                                    },
                          "Body":  {
                                       "en":  "Empties the temporary folders of Windows and your user. Programs recreate what they need.",
                                       "es":  "Vacía las carpetas temporales de Windows y de tu usuario. Los programas vuelven a crear lo que necesitan."
                                   },
                          "Details":  {
                                          "en":  [
                                                     "Empties %TEMP% and C:\\Windows\\Temp.",
                                                     "Files in use are skipped.",
                                                     "Deleted files do not go to the Recycle Bin."
                                                 ],
                                          "es":  [
                                                     "Vacía %TEMP% y C:\\Windows\\Temp.",
                                                     "Los archivos en uso se saltan.",
                                                     "Los archivos borrados no van a la Papelera."
                                                 ]
                                      },
                          "Summary":  {
                                          "en":  "Delete temporary files",
                                          "es":  "Borrar archivos temporales"
                                      },
                          "Recommended":  true,
                          "Reversible":  false,
                          "Actions":  [
                                          {
                                              "Key":  "WPFTweaksDeleteTempFiles"
                                          }
                                      ]
                      },
                      {
                          "Id":  "PauseUpdates",
                          "Section":  "advanced",
                          "Category":  {
                                           "en":  "Advanced",
                                           "es":  "Avanzado"
                                       },
                          "Title":  {
                                        "en":  "Pause Windows Update until 2099?",
                                        "es":  "¿Pausar Windows Update hasta 2099?"
                                    },
                          "Body":  {
                                       "en":  "Stops Windows from updating and restarting the PC on its own. It only changes the pause dates in the registry: no services or Windows files are touched.",
                                       "es":  "Evita que Windows se actualice solo y reinicie el equipo. Solo cambia las fechas de pausa en el Registro: no toca servicios ni archivos de Windows."
                                   },
                          "Details":  {
                                          "en":  [
                                                     "Writes pause dates until 2099 for quality, feature and general updates.",
                                                     "The previous values are saved; Undo restores them.",
                                                     "No service is disabled and no file is renamed."
                                                 ],
                                          "es":  [
                                                     "Escribe fechas de pausa hasta 2099 para actualizaciones de calidad, de características y generales.",
                                                     "Se guardan los valores anteriores; Deshacer los restaura.",
                                                     "No se deshabilita ningún servicio ni se renombra ningún archivo."
                                                 ]
                                      },
                          "Note":  {
                                       "en":  "You will not receive security updates either. Microsoft only supports 35-day pauses, so Windows may ignore or reset the date.",
                                       "es":  "Tampoco recibirás actualizaciones de seguridad. Microsoft solo admite pausas de 35 días, así que Windows puede ignorar la fecha o reiniciarla."
                                   },
                          "Summary":  {
                                          "en":  "Pause Windows Update until 2099",
                                          "es":  "Pausar Windows Update hasta 2099"
                                      },
                          "YesLabel":  {
                                           "en":  "Yes, pause",
                                           "es":  "Sí, pausar"
                                       },
                          "Recommended":  false,
                          "Reversible":  true,
                          "Actions":  [
                                          {
                                              "Key":  "WPFTweaksPauseWindows2099"
                                          }
                                      ]
                      },
                      {
                          "Id":  "WindowsSearch",
                          "Section":  "advanced",
                          "Category":  {
                                           "en":  "Advanced",
                                           "es":  "Avanzado"
                                       },
                          "Title":  {
                                        "en":  "Turn off Windows Search indexing?",
                                        "es":  "¿Desactivar la indexación de Windows Search?"
                                    },
                          "Body":  {
                                       "en":  "Stops the Windows Search service from indexing files in the background, which reduces disk and CPU use.",
                                       "es":  "Detiene el servicio Windows Search para que no indexe archivos en segundo plano, lo que reduce el uso de disco y CPU."
                                   },
                          "Details":  {
                                          "en":  [
                                                     "Windows Search service (WSearch): stopped and disabled.",
                                                     "Undo sets it back to Automatic (delayed start).",
                                                     "Search still works, but it scans the disk each time instead of using the index."
                                                 ],
                                          "es":  [
                                                     "Servicio Windows Search (WSearch): detenido y deshabilitado.",
                                                     "Deshacer lo vuelve a Automático (inicio retrasado).",
                                                     "La búsqueda sigue funcionando, pero recorre el disco cada vez en lugar de usar el índice."
                                                 ]
                                      },
                          "Note":  {
                                       "en":  "File, Start and Outlook searches can become slow or stop finding results.",
                                       "es":  "Las búsquedas de archivos, de Inicio y de Outlook pueden volverse lentas o dejar de encontrar resultados."
                                   },
                          "Summary":  {
                                          "en":  "Turn off Windows Search indexing",
                                          "es":  "Desactivar indexación de Windows Search"
                                      },
                          "Recommended":  false,
                          "Reversible":  true,
                          "Actions":  [
                                          {
                                              "Key":  "WPFTweaksDisableWindowsSearch"
                                          }
                                      ]
                      },
                      {
                          "Id":  "SearchWebView2",
                          "Section":  "advanced",
                          "Category":  {
                                           "en":  "Background processes",
                                           "es":  "Procesos en segundo plano"
                                       },
                          "Title":  {
                                        "en":  "Stop Start search from keeping WebView2 open in the background?",
                                        "es":  "¿Evitar que la búsqueda de Inicio deje WebView2 abierto en segundo plano?"
                                    },
                          "Body":  {
                                       "en":  "SearchHost.exe keeps several msedgewebview2.exe processes open to draw the Start search panel, even when you are not searching.",
                                       "es":  "SearchHost.exe mantiene abiertos varios procesos msedgewebview2.exe para dibujar el panel de búsqueda de Inicio, aunque no estés buscando."
                                   },
                          "Details":  {
                                          "en":  [
                                                     "The msedgewebview2.exe processes of Start search stop running in the background.",
                                                     "Start search goes back to the previous interface.",
                                                     "It takes effect after restarting; Undo brings everything back."
                                                 ],
                                          "es":  [
                                                     "Los procesos msedgewebview2.exe de la búsqueda de Inicio dejan de correr en segundo plano.",
                                                     "La búsqueda de Inicio vuelve a la interfaz anterior.",
                                                     "Se aplica después de reiniciar; Deshacer vuelve todo como estaba."
                                                 ]
                                      },
                          "Note":  {
                                       "en":  "A Windows update can change these features; the change then stops having an effect.",
                                       "es":  "Una actualización de Windows puede cambiar estas funciones y entonces el cambio deja de tener efecto."
                                   },
                          "Summary":  {
                                          "en":  "Turn off WebView2 in Start search",
                                          "es":  "Desactivar WebView2 de la búsqueda de Inicio"
                                      },
                          "Recommended":  false,
                          "Reversible":  true,
                          "Reboot":  true,
                          "Actions":  [
                                          {
                                              "Key":  "WPFTweaksDisableSearchWebView2"
                                          }
                                      ]
                      },
                      {
                          "Id":  "UCPD",
                          "Section":  "advanced",
                          "Category":  {
                                           "en":  "Advanced",
                                           "es":  "Avanzado"
                                       },
                          "Title":  {
                                        "en":  "Disable UCPD (default apps protection)?",
                                        "es":  "¿Desactivar UCPD (protección de apps predeterminadas)?"
                                    },
                          "Body":  {
                                       "en":  "UCPD stops tools from changing your default browser, PDF reader and other defaults. Disable it only if you need a tool to change them.",
                                       "es":  "UCPD impide que las herramientas cambien tu navegador, lector de PDF y otras apps predeterminadas. Desactívalo solo si necesitas que una herramienta las cambie."
                                   },
                          "Details":  {
                                          "en":  [
                                                     "UCPD.sys driver: startup set to disabled.",
                                                     "Scheduled task \"UCPD velocity\": disabled so it does not turn the driver back on.",
                                                     "The original state is saved; Undo restores it."
                                                 ],
                                          "es":  [
                                                     "Driver UCPD.sys: inicio deshabilitado.",
                                                     "Tarea programada \"UCPD velocity\": desactivada para que no vuelva a activar el driver.",
                                                     "Se guarda el estado original; Deshacer lo restaura."
                                                 ]
                                      },
                          "Note":  {
                                       "en":  "This turns off a Windows protection. Windows Update may turn it back on.",
                                       "es":  "Desactiva una protección de Windows. Windows Update puede volver a activarla."
                                   },
                          "Summary":  {
                                          "en":  "Disable UCPD",
                                          "es":  "Desactivar UCPD"
                                      },
                          "Recommended":  false,
                          "Reversible":  true,
                          "Reboot":  true,
                          "Actions":  [
                                          {
                                              "Key":  "WPFTweaksDisableUCPD"
                                          }
                                      ]
                      },
                      {
                          "Id":  "CPUMitigations",
                          "Section":  "advanced",
                          "Category":  {
                                           "en":  "Processor",
                                           "es":  "Procesador"
                                       },
                          "Title":  {
                                        "en":  "Turn off CPU mitigations (Spectre/Meltdown)?",
                                        "es":  "¿Desactivar las mitigaciones de CPU (Spectre/Meltdown)?"
                                    },
                          "Body":  {
                                       "en":  "Windows blocks attacks that read memory through the processor, at some performance cost. Turning the protection off can win that performance back on older CPUs, but leaves the PC more exposed.",
                                       "es":  "Windows bloquea ataques que leen memoria a través del procesador, a costa de algo de rendimiento. Desactivar esa protección puede recuperar rendimiento en CPUs viejas, pero deja la PC más expuesta."
                                   },
                          "Details":  {
                                          "en":  [
                                                     "Writes FeatureSettingsOverride = 3 and FeatureSettingsOverrideMask = 3 in Memory Management.",
                                                     "Turns off the Windows mitigations for Spectre variant 2 and Meltdown.",
                                                     "The original values are saved; Undo restores them.",
                                                     "It takes effect after restarting."
                                                 ],
                                          "es":  [
                                                     "Escribe FeatureSettingsOverride = 3 y FeatureSettingsOverrideMask = 3 en Memory Management.",
                                                     "Desactiva las mitigaciones de Windows para Spectre variante 2 y Meltdown.",
                                                     "Se guardan los valores originales; Deshacer los restaura.",
                                                     "Se aplica después de reiniciar."
                                                 ]
                                      },
                          "Note":  {
                                       "en":  "Lowers security, especially with untrusted programs or websites. Do not use it on PCs with work or sensitive data.",
                                       "es":  "Baja la seguridad, sobre todo con programas o sitios web no confiables. No lo uses en PCs con datos de trabajo o sensibles."
                                   },
                          "Summary":  {
                                          "en":  "Turn off CPU mitigations",
                                          "es":  "Desactivar mitigaciones de CPU"
                                      },
                          "YesLabel":  {
                                           "en":  "Yes, turn off",
                                           "es":  "Sí, desactivar"
                                       },
                          "Advice":  "CPUMitigations",
                          "Recommended":  false,
                          "Reversible":  true,
                          "Reboot":  true,
                          "Actions":  [
                                          {
                                              "Key":  "WPFTweaksDisableCPUMitigations"
                                          }
                                      ]
                      }
                  ]
}
'@ | ConvertFrom-Json
$sync.configs.localization = @'
{
    "es":  {
               "WPFTab2BT":  {
                                 "Content":  "Ajustes"
                             },
               "WPFAdvancedTabBT":  {
                                        "Content":  "Avanzado"
                                    },
               "WPFTab2":  {
                               "Header":  "Ajustes"
                           },
               "WPFAdvancedTab":  {
                                      "Header":  "Avanzado"
                                  },
               "SearchBar":  {
                                 "ToolTip":  "Buscar ajustes de Windows. Ctrl+F para buscar; Esc para limpiar."
                             },
               "ThemeButton":  {
                                   "ToolTip":  "Cambiar el tema de APBOptimizer"
                               },
               "FontScalingButton":  {
                                         "ToolTip":  "Ajustar el tamaño de letra"
                                     },
               "SettingsButton":  {
                                      "ToolTip":  "Configuración"
                                  },
               "WPFMinimizeButton":  {
                                         "ToolTip":  "Minimizar"
                                     },
               "WPFCloseButton":  {
                                      "ToolTip":  "Cerrar"
                                  },
               "AutoThemeMenuItem":  {
                                         "Header":  "Automático"
                                     },
               "DarkThemeMenuItem":  {
                                         "Header":  "Oscuro"
                                     },
               "LightThemeMenuItem":  {
                                          "Header":  "Claro"
                                      },
               "ImportMenuItem":  {
                                      "Header":  "Importar"
                                  },
               "ExportMenuItem":  {
                                      "Header":  "Exportar"
                                  },
               "AboutMenuItem":  {
                                     "Header":  "Acerca de"
                                 },
               "WPFLanguageLabel":  {
                                        "Text":  "Idioma"
                                    },
               "WPFLanguageSelector":  {
                                           "ToolTip":  "Selecciona el idioma de la interfaz. Automático usa el idioma de Windows."
                                       },
               "WPFFontScalingTitle":  {
                                           "Text":  "Tamaño de letra"
                                       },
               "WPFFontSmall":  {
                                    "Text":  "Pequeño"
                                },
               "WPFFontLarge":  {
                                    "Text":  "Grande"
                                },
               "FontScalingResetButton":  {
                                              "Content":  "Restablecer"
                                          },
               "FontScalingApplyButton":  {
                                              "Content":  "Aplicar"
                                          },
               "WPFRecommendedLabel":  {
                                           "Content":  "Selecciones recomendadas:"
                                       },
               "WPFstandard":  {
                                   "Content":  " Estándar "
                               },
               "WPFminimal":  {
                                  "Content":  " Mínimo "
                              },
               "WPFAdvanced":  {
                                   "Content":  " Avanzado "
                               },
               "WPFClearTweaksSelection":  {
                                               "Content":  " Limpiar "
                                           },
               "WPFGetInstalledTweaks":  {
                                             "Content":  " Seleccionar ajustes aplicados "
                                         },
               "WPFTweaksbutton":  {
                                       "Content":  "Aplicar ajustes"
                                   },
               "WPFUndoall":  {
                                  "Content":  "Deshacer ajustes seleccionados"
                              },
               "WPFInfoNote":  {
                                   "Text":  "Nota: pasa el cursor sobre los ajustes para leer su descripción. Algunos modifican profundamente Windows. Los perfiles recomendados son para uso normal; si tienes dudas, no selecciones otras opciones."
                               },
               "WPFAdvancedHeading":  {
                                          "Text":  "Avanzado"
                                      },
               "WPFWindowsUpdateHeading":  {
                                               "Text":  "Windows Update"
                                           },
               "WPFWindowsUpdateDescription":  {
                                                   "Text":  "Modo agresivo: deshabilita servicios e intenta renombrar DLL protegidas de Windows Update. Puede impedir actualizaciones y reparaciones del sistema. La restauración utiliza los permisos originales guardados. Requiere permisos de administrador."
                                               },
               "WPFWindowsUpdateStatus":  {
                                              "Text":  "Consultando el estado de Windows Update..."
                                          },
               "WPFDisableWindowsUpdate":  {
                                               "Content":  "Desactivar Windows Update"
                                           },
               "WPFRestoreWindowsUpdate":  {
                                               "Content":  "Restaurar Windows Update"
                                           },
               "GuidedModeMenuItem":  {
                                          "Header":  "Modo guiado"
                                      }
           },
    "en":  {

           }
}
'@ | ConvertFrom-Json
$sync.configs.preset = @'
{
    "Standard":  [
                     "WPFTweaksActivity",
                     "WPFTweaksConsumerFeatures",
                     "WPFTweaksDisableExplorerAutoDiscovery",
                     "WPFTweaksWPBT",
                     "WPFTweaksLocation",
                     "WPFTweaksServices",
                     "WPFTweaksTelemetry",
                     "WPFTweaksDeliveryOptimization",
                     "WPFTweaksDiskCleanup",
                     "WPFTweaksDeleteTempFiles",
                     "WPFTweaksEndTaskOnTaskbar",
                     "WPFTweaksRestorePoint"
                 ],
    "Minimal":  [
                    "WPFTweaksConsumerFeatures",
                    "WPFTweaksWPBT",
                    "WPFTweaksServices",
                    "WPFTweaksTelemetry"
                ],
    "Advanced":  [
                     "WPFTweaksRestorePoint",
                     "WPFTweaksActivity",
                     "WPFTweaksConsumerFeatures",
                     "WPFTweaksDisableExplorerAutoDiscovery",
                     "WPFTweaksWPBT",
                     "WPFTweaksLocation",
                     "WPFTweaksServices",
                     "WPFTweaksTelemetry",
                     "WPFTweaksDeliveryOptimization",
                     "WPFTweaksDeleteTempFiles",
                     "WPFTweaksEndTaskOnTaskbar",
                     "WPFTweaksDisableStoreSearch",
                     "WPFTweaksRevertStartMenu",
                     "WPFTweaksWidget",
                     "WPFTweaksRemoveOneDrive",
                     "WPFTweaksWindowsAI",
                     "WPFTweaksRightClickMenu"
                 ]
}
'@ | ConvertFrom-Json
$sync.configs.themes = @'
{
    "shared":  {
                   "AppEntryWidth":  "220",
                   "AppEntryFontSize":  "13.2",
                   "AppEntryIconSize":  "28",
                   "AppEntryMargin":  "3",
                   "AppEntryBorderThickness":  "1",
                   "CustomDialogFontSize":  "12",
                   "CustomDialogFontSizeHeader":  "14",
                   "CustomDialogLogoSize":  "25",
                   "CustomDialogWidth":  "400",
                   "CustomDialogHeight":  "200",
                   "FontSize":  "12",
                   "FontFamily":  "Arial",
                   "HeaderFontSize":  "16",
                   "Win11StepTitleFontSize":  "22",
                   "Win11StepHeroFontSize":  "40",
                   "Win11LogFontFamily":  "Consolas, Monaco",
                   "HeaderFontFamily":  "Consolas, Monaco",
                   "CheckBoxBulletDecoratorSize":  "14",
                   "CheckBoxMargin":  "15,0,0,2",
                   "TabContentMargin":  "5",
                   "TabButtonFontSize":  "14",
                   "TabButtonWidth":  "110",
                   "TabButtonHeight":  "26",
                   "TabRowHeightInPixels":  "50",
                   "ToolTipWidth":  "300",
                   "IconFontSize":  "14",
                   "IconButtonSize":  "35",
                   "SettingsIconFontSize":  "18",
                   "CloseIconFontSize":  "12",
                   "GroupBorderBackgroundColor":  "#232629",
                   "ButtonFontSize":  "12",
                   "ButtonFontFamily":  "Arial",
                   "ButtonWidth":  "200",
                   "ButtonHeight":  "25",
                   "ConfigTabButtonFontSize":  "14",
                   "ConfigUpdateButtonFontSize":  "14",
                   "SearchBarWidth":  "200",
                   "SearchBarHeight":  "26",
                   "SearchBarTextBoxFontSize":  "12",
                   "SearchBarClearButtonFontSize":  "14",
                   "CheckboxMouseOverColor":  "#999999",
                   "ButtonBorderThickness":  "1",
                   "ButtonMargin":  "1",
                   "ButtonCornerRadius":  "2"
               },
    "Light":  {
                  "AppInstallUnselectedColor":  "#F7F7F7",
                  "AppInstallHighlightedColor":  "#CFCFCF",
                  "AppInstallSelectedColor":  "#C2C2C2",
                  "ComboBoxForegroundColor":  "#232629",
                  "ComboBoxBackgroundColor":  "#F7F7F7",
                  "LabelboxForegroundColor":  "#232629",
                  "MainForegroundColor":  "#232629",
                  "MainBackgroundColor":  "#F7F7F7",
                  "TweakHelpBackgroundColor":  "#F7F7F7",
                  "TweakHelpBorderColor":  "#CFCFCF",
                  "TweakHelpHeaderColor":  "#F5F5F5",
                  "TweakHelpSectionColor":  "#FFFFFF",
                  "TweakHelpShadowColor":  "#B7B7B7",
                  "LabelBackgroundColor":  "#F7F7F7",
                  "LinkForegroundColor":  "#484848",
                  "LinkHoverForegroundColor":  "#232629",
                  "ScrollBarBackgroundColor":  "#4A4D52",
                  "ScrollBarHoverColor":  "#5A5D62",
                  "ScrollBarDraggingColor":  "#6A6D72",
                  "ProgressBarForegroundColor":  "#2E77FF",
                  "ProgressBarErrorColor":  "#D13438",
                  "ProgressBarWarningColor":  "#B36A00",
                  "ProgressBarBackgroundColor":  "Transparent",
                  "ButtonInstallBackgroundColor":  "#F7F7F7",
                  "ButtonTweaksBackgroundColor":  "#F7F7F7",
                  "ButtonConfigBackgroundColor":  "#F7F7F7",
                  "ButtonUpdatesBackgroundColor":  "#F7F7F7",
                  "ButtonWin11ISOBackgroundColor":  "#F7F7F7",
                  "ButtonAppxBackgroundColor":  "#F7F7F7",
                  "ButtonInstallForegroundColor":  "#232629",
                  "ButtonTweaksForegroundColor":  "#232629",
                  "ButtonConfigForegroundColor":  "#232629",
                  "ButtonUpdatesForegroundColor":  "#232629",
                  "ButtonWin11ISOForegroundColor":  "#232629",
                  "ButtonAppxForegroundColor":  "#232629",
                  "ButtonBackgroundColor":  "#F5F5F5",
                  "ButtonBackgroundPressedColor":  "#1A1A1A",
                  "ButtonBackgroundMouseoverColor":  "#C2C2C2",
                  "ButtonBackgroundSelectedColor":  "#F0F0F0",
                  "ButtonForegroundColor":  "#232629",
                  "ToggleButtonOnColor":  "#2E77FF",
                  "ToggleButtonOffColor":  "#707070",
                  "ToolTipBackgroundColor":  "#F7F7F7",
                  "BorderColor":  "#232629",
                  "BorderOpacity":  "0.2"
              },
    "Dark":  {
                 "AppInstallUnselectedColor":  "#232629",
                 "AppInstallHighlightedColor":  "#3C3C3C",
                 "AppInstallSelectedColor":  "#4C4C4C",
                 "ComboBoxForegroundColor":  "#F7F7F7",
                 "ComboBoxBackgroundColor":  "#1E3747",
                 "LabelboxForegroundColor":  "#5BDCFF",
                 "MainForegroundColor":  "#F7F7F7",
                 "MainBackgroundColor":  "#232629",
                 "TweakHelpBackgroundColor":  "#232629",
                 "TweakHelpBorderColor":  "#4A4D52",
                 "TweakHelpHeaderColor":  "#2E3135",
                 "TweakHelpSectionColor":  "#2F373D",
                 "TweakHelpShadowColor":  "#191B1D",
                 "LabelBackgroundColor":  "#232629",
                 "LinkForegroundColor":  "#ADD8E6",
                 "LinkHoverForegroundColor":  "#F7F7F7",
                 "ScrollBarBackgroundColor":  "#2E3135",
                 "ScrollBarHoverColor":  "#3B4252",
                 "ScrollBarDraggingColor":  "#5E81AC",
                 "ProgressBarForegroundColor":  "#6EFF72",
                 "ProgressBarErrorColor":  "#FF6B6B",
                 "ProgressBarWarningColor":  "#FFC83D",
                 "ProgressBarBackgroundColor":  "Transparent",
                 "ButtonInstallBackgroundColor":  "#222222",
                 "ButtonTweaksBackgroundColor":  "#333333",
                 "ButtonConfigBackgroundColor":  "#444444",
                 "ButtonUpdatesBackgroundColor":  "#555555",
                 "ButtonWin11ISOBackgroundColor":  "#666666",
                 "ButtonAppxBackgroundColor":  "#777777",
                 "ButtonInstallForegroundColor":  "#F7F7F7",
                 "ButtonTweaksForegroundColor":  "#F7F7F7",
                 "ButtonConfigForegroundColor":  "#F7F7F7",
                 "ButtonUpdatesForegroundColor":  "#F7F7F7",
                 "ButtonWin11ISOForegroundColor":  "#F7F7F7",
                 "ButtonAppxForegroundColor":  "#F7F7F7",
                 "ButtonBackgroundColor":  "#1E3747",
                 "ButtonBackgroundPressedColor":  "#F7F7F7",
                 "ButtonBackgroundMouseoverColor":  "#3B4252",
                 "ButtonBackgroundSelectedColor":  "#5E81AC",
                 "ButtonForegroundColor":  "#F7F7F7",
                 "ToggleButtonOnColor":  "#2E77FF",
                 "ToggleButtonOffColor":  "#707070",
                 "ToolTipBackgroundColor":  "#2F373D",
                 "BorderColor":  "#2F373D",
                 "BorderOpacity":  "0.2"
             }
}
'@ | ConvertFrom-Json
$sync.configs.tweaks = @'
{
    "WPFTweaksActivity":  {
                              "Content":  "Activity History - Disable",
                              "Description":  "Stops Windows from publishing or uploading user activities while preserving clipboard history.",
                              "category":  "Essential Tweaks",
                              "panel":  "1",
                              "registry":  [
                                               {
                                                   "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\System",
                                                   "Name":  "EnableActivityFeed",
                                                   "Value":  "1",
                                                   "Type":  "DWord",
                                                   "OriginalValue":  "\u003cRemoveEntry\u003e"
                                               },
                                               {
                                                   "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\System",
                                                   "Name":  "PublishUserActivities",
                                                   "Value":  "0",
                                                   "Type":  "DWord",
                                                   "OriginalValue":  "\u003cRemoveEntry\u003e"
                                               },
                                               {
                                                   "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\System",
                                                   "Name":  "UploadUserActivities",
                                                   "Value":  "0",
                                                   "Type":  "DWord",
                                                   "OriginalValue":  "\u003cRemoveEntry\u003e"
                                               }
                                           ],
                              "link":  "https://winutil.christitus.com/code-reference/tweaks/essential-tweaks/activity"
                          },
    "WPFTweaksHiber":  {
                           "Content":  "Hibernation - Disable",
                           "Description":  "Hibernation is really meant for laptops as it saves what\u0027s in memory before turning the PC off. It really should never be used.",
                           "category":  "Essential Tweaks",
                           "panel":  "1",
                           "registry":  [
                                            {
                                                "Path":  "HKLM:\\System\\CurrentControlSet\\Control\\Session Manager\\Power",
                                                "Name":  "HibernateEnabled",
                                                "Value":  "0",
                                                "Type":  "DWord",
                                                "OriginalValue":  "1"
                                            },
                                            {
                                                "Path":  "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Explorer\\FlyoutMenuSettings",
                                                "Name":  "ShowHibernateOption",
                                                "Value":  "0",
                                                "Type":  "DWord",
                                                "OriginalValue":  "1"
                                            }
                                        ],
                           "InvokeScript":  [
                                                "powercfg.exe /hibernate off"
                                            ],
                           "UndoScript":  [
                                              "powercfg.exe /hibernate on"
                                          ],
                           "link":  "https://winutil.christitus.com/code-reference/tweaks/essential-tweaks/hiber"
                       },
    "WPFTweaksWidget":  {
                            "Content":  "Widgets - Remove",
                            "Description":  "Removes the annoying widgets in the bottom left of the Taskbar.",
                            "category":  "Essential Tweaks",
                            "panel":  "1",
                            "InvokeScript":  [
                                                 "\n      # Sometimes if you dont stop the Widgets process the removal may fail\n\n      Get-Process *Widget* | Stop-Process\n      Get-AppxPackage Microsoft.WidgetsPlatformRuntime -AllUsers | Remove-AppxPackage -AllUsers\n      Get-AppxPackage MicrosoftWindows.Client.WebExperience -AllUsers | Remove-AppxPackage -AllUsers\n\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\n      Write-Host \"Removed widgets\"\n      "
                                             ],
                            "link":  "https://winutil.christitus.com/code-reference/tweaks/essential-tweaks/widget"
                        },
    "WPFTweaksRevertStartMenu":  {
                                     "Content":  "Start Menu Previous Layout - Enable",
                                     "Description":  "Bring back the old Start Menu layout from before the gradual rollout of the new one in 25H2. On newer versions of Windows !!THIS TWEAK WILL NOT WORK!!",
                                     "category":  "Essential Tweaks",
                                     "panel":  "1",
                                     "registry":  [
                                                      {
                                                          "Path":  "HKLM:\\SYSTEM\\ControlSet001\\Control\\FeatureManagement\\Overrides\\8\\3036241548",
                                                          "Name":  "EnabledState",
                                                          "Value":  "1",
                                                          "Type":  "DWord",
                                                          "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                      }
                                                  ],
                                     "link":  "https://winutil.christitus.com/code-reference/tweaks/essential-tweaks/revertstartmenu"
                                 },
    "WPFTweaksDisableStoreSearch":  {
                                        "Content":  "Microsoft Store Recommended Search Results - Disable",
                                        "Description":  "Will not display recommended Microsoft Store apps when searching for apps in the Start menu.",
                                        "category":  "Essential Tweaks",
                                        "panel":  "1",
                                        "InvokeScript":  [
                                                             "icacls \"$Env:LocalAppData\\Packages\\Microsoft.WindowsStore_8wekyb3d8bbwe\\LocalState\\store.db\" /deny *S-1-1-0:F"
                                                         ],
                                        "UndoScript":  [
                                                           "icacls \"$Env:LocalAppData\\Packages\\Microsoft.WindowsStore_8wekyb3d8bbwe\\LocalState\\store.db\" /grant *S-1-1-0:F"
                                                       ],
                                        "link":  "https://winutil.christitus.com/code-reference/tweaks/essential-tweaks/disablestoresearch"
                                    },
    "WPFTweaksLocation":  {
                              "Content":  "Location Tracking - Disable",
                              "Description":  "Disables Location Tracking.",
                              "category":  "Essential Tweaks",
                              "panel":  "1",
                              "service":  [
                                              {
                                                  "Name":  "lfsvc",
                                                  "StartupType":  "Disabled",
                                                  "OriginalType":  "Manual"
                                              }
                                          ],
                              "registry":  [
                                               {
                                                   "Path":  "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\CapabilityAccessManager\\ConsentStore\\location",
                                                   "Name":  "Value",
                                                   "Value":  "Deny",
                                                   "Type":  "String",
                                                   "OriginalValue":  "Allow"
                                               },
                                               {
                                                   "Path":  "HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Sensor\\Overrides\\{BFA794E4-F964-4FDB-90F6-51056BFE4B44}",
                                                   "Name":  "SensorPermissionState",
                                                   "Value":  "0",
                                                   "Type":  "DWord",
                                                   "OriginalValue":  "1"
                                               },
                                               {
                                                   "Path":  "HKLM:\\SYSTEM\\Maps",
                                                   "Name":  "AutoUpdateEnabled",
                                                   "Value":  "0",
                                                   "Type":  "DWord",
                                                   "OriginalValue":  "1"
                                               }
                                           ],
                              "link":  "https://winutil.christitus.com/code-reference/tweaks/essential-tweaks/location"
                          },
    "WPFTweaksServices":  {
                              "Content":  "Services - Set to Manual",
                              "Description":  "Sets some services to Manual startup and adjusts the SvcHostSplitThresholdInKB registry value to better match system memory, which can significantly reduce the number of svchost.exe processes.",
                              "category":  "Essential Tweaks",
                              "panel":  "1",
                              "service":  [
                                              {
                                                  "Name":  "CscService",
                                                  "StartupType":  "Disabled",
                                                  "OriginalType":  "Manual"
                                              },
                                              {
                                                  "Name":  "DiagTrack",
                                                  "StartupType":  "Disabled",
                                                  "OriginalType":  "Automatic"
                                              },
                                              {
                                                  "Name":  "MapsBroker",
                                                  "StartupType":  "Manual",
                                                  "OriginalType":  "Automatic"
                                              },
                                              {
                                                  "Name":  "StorSvc",
                                                  "StartupType":  "Manual",
                                                  "OriginalType":  "Automatic"
                                              },
                                              {
                                                  "Name":  "SharedAccess",
                                                  "StartupType":  "Disabled",
                                                  "OriginalType":  "Automatic"
                                              }
                                          ],
                              "InvokeScript":  [
                                                   "\n      $Memory = (Get-CimInstance Win32_PhysicalMemory | Measure-Object Capacity -Sum).Sum / 1KB\n      Set-ItemProperty -Path \"HKLM:\\SYSTEM\\CurrentControlSet\\Control\" -Name SvcHostSplitThresholdInKB -Value $Memory\n      "
                                               ],
                              "link":  "https://winutil.christitus.com/code-reference/tweaks/essential-tweaks/services"
                          },
    "WPFServiceGroupDiagnostics":  {
                                       "Content":  "Disable Diagnostic Services",
                                       "Description":  "Expand the arrow to choose Windows diagnostic and telemetry services: diagnostic hosts, Diagnostic Policy Service, DiagTrack, Error Reporting and the Diagnostics Hub collector. Marking or unmarking only prepares changes; press Apply Tweaks to disable selected services or restore unchecked services. The main checkbox selects all available services. Disabling them stops Windows troubleshooters, problem detection and error reports.",
                                       "Type":  "ServiceGroup",
                                       "category":  "z__Advanced Tweaks - CAUTION",
                                       "panel":  "1",
                                       "Children":  [
                                                        "WPFToggleServiceWdiSystemHost",
                                                        "WPFToggleServiceWdiServiceHost",
                                                        "WPFToggleServiceDPS",
                                                        "WPFToggleServiceDiagTrack",
                                                        "WPFToggleServiceWerSvc",
                                                        "WPFToggleServiceDiagnosticsHub"
                                                    ],
                                       "link":  "https://learn.microsoft.com/en-us/windows/iot/iot-enterprise/optimize/services"
                                   },
    "WPFServiceGroupUseless":  {
                                   "Content":  "Disable Useless Services",
                                   "Description":  "Expand the arrow to choose optional Windows services. Marking or unmarking only prepares changes; press Apply Tweaks to disable selected services or restore unchecked services. The main checkbox selects all available services. Some support AutoPlay, device management or .NET networking. NetTcpPortSharing is often disabled by default; restoring it sets Manual startup.",
                                   "Type":  "ServiceGroup",
                                   "category":  "z__Advanced Tweaks - CAUTION",
                                   "panel":  "1",
                                   "Children":  [
                                                    "WPFToggleServiceShellHWDetection",
                                                    "WPFToggleServiceWMPNetworkSvc",
                                                    "WPFToggleServicewisvc",
                                                    "WPFToggleServiceFontCache3000",
                                                    "WPFToggleServiceRetailDemo",
                                                    "WPFToggleServiceDmwappushservice",
                                                    "WPFToggleServiceWhesvc",
                                                    "WPFToggleServiceNetTcpPortSharing"
                                                ],
                                   "link":  "https://learn.microsoft.com/en-us/windows/iot/iot-enterprise/optimize/services"
                               },
    "WPFDriverGroupOptional":  {
                                   "Content":  "Disable Useless Drivers (advanced)",
                                   "Description":  "Optional kernel drivers, NOT a recommended preset. Marking or unmarking only queues changes until Apply Tweaks, when driver disables require confirmation. Original startup settings are backed up for Undo. Boot/System and critical drivers are locked; missing drivers are hidden. Changes take effect after reboot and may affect media, networking or power monitoring. Does not delete .sys files. UCPD.sys remains a separate advanced tweak.",
                                   "Type":  "DriverGroup",
                                   "category":  "z__Advanced Tweaks - CAUTION",
                                   "panel":  "1",
                                   "Children":  [
                                                    "WPFToggleDriverTelemetry",
                                                    "WPFToggleDriverPEAUTH",
                                                    "WPFToggleDriverTcpipreg",
                                                    "WPFToggleDriverIntelPMT",
                                                    "WPFToggleDriverGpuEnergyDrv",
                                                    "WPFToggleDriverIObitUnlocker"
                                                ],
                                   "link":  "https://learn.microsoft.com/en-us/windows-hardware/drivers/install/registry-trees-and-keys"
                               },
    "WPFToggleDriverTelemetry":  {
                                     "Content":  "Intel Telemetry driver (Telemetry / 20H2)",
                                     "Description":  "Optional Intel Telemetry driver on certain installations, not the Windows DiagTrack service. If its startup is already Disabled (as in some 20H2 images), APBOptimizer leaves it unchanged and cannot invent its previous state.",
                                     "Type":  "Toggle",
                                     "ParentGroup":  "WPFDriverGroupOptional",
                                     "category":  "z__Advanced Tweaks - CAUTION",
                                     "panel":  "1",
                                     "driver":  {
                                                    "Name":  "Telemetry"
                                                },
                                     "InvokeScript":  [
                                                          "Set-WinUtilOptionalDriver -Name Telemetry -Mode Disable"
                                                      ],
                                     "UndoScript":  [
                                                        "Set-WinUtilOptionalDriver -Name Telemetry -Mode Restore"
                                                    ]
                                 },
    "WPFToggleDriverPEAUTH":  {
                                  "Content":  "Protected Environment Authentication (PEAUTH.sys)",
                                  "Description":  "Windows protected media authentication. Disabling may break DRM playback and protected media. Blocked if Boot/System/critical. Only change if you understand the side effects.",
                                  "Type":  "Toggle",
                                  "ParentGroup":  "WPFDriverGroupOptional",
                                  "category":  "z__Advanced Tweaks - CAUTION",
                                  "panel":  "1",
                                  "driver":  {
                                                 "Name":  "PEAUTH"
                                             },
                                  "InvokeScript":  [
                                                       "Set-WinUtilOptionalDriver -Name PEAUTH -Mode Disable"
                                                   ],
                                  "UndoScript":  [
                                                     "Set-WinUtilOptionalDriver -Name PEAUTH -Mode Restore"
                                                 ],
                                  "link":  "https://learn.microsoft.com/en-us/windows/win32/medfound/protected-media-path"
                              },
    "WPFToggleDriverTcpipreg":  {
                                    "Content":  "TCP/IP Registry Compatibility (tcpipreg.sys)",
                                    "Description":  "Compatibility for software that reads legacy TCP/IP settings through the registry. This is not the main TCP/IP driver, but disabling can impair older networking applications. Boot/System startup is protected.",
                                    "Type":  "Toggle",
                                    "ParentGroup":  "WPFDriverGroupOptional",
                                    "category":  "z__Advanced Tweaks - CAUTION",
                                    "panel":  "1",
                                    "driver":  {
                                                   "Name":  "tcpipreg"
                                               },
                                    "InvokeScript":  [
                                                         "Set-WinUtilOptionalDriver -Name tcpipreg -Mode Disable"
                                                     ],
                                    "UndoScript":  [
                                                       "Set-WinUtilOptionalDriver -Name tcpipreg -Mode Restore"
                                                   ]
                                },
    "WPFToggleDriverIntelPMT":  {
                                    "Content":  "Intel Platform Monitoring (IntelPMT.sys)",
                                    "Description":  "Intel platform telemetry used by monitoring, management and potentially power/performance software. Can affect Intel OEM and tuning functions. Not necessarily unnecessary on Intel laptops.",
                                    "Type":  "Toggle",
                                    "ParentGroup":  "WPFDriverGroupOptional",
                                    "category":  "z__Advanced Tweaks - CAUTION",
                                    "panel":  "1",
                                    "driver":  {
                                                   "Name":  "IntelPMT"
                                               },
                                    "InvokeScript":  [
                                                         "Set-WinUtilOptionalDriver -Name IntelPMT -Mode Disable"
                                                     ],
                                    "UndoScript":  [
                                                       "Set-WinUtilOptionalDriver -Name IntelPMT -Mode Restore"
                                                   ],
                                    "link":  "https://github.com/intel/Intel-PMT"
                                },
    "WPFToggleDriverGpuEnergyDrv":  {
                                        "Content":  "GPU Energy Kernel Driver (GpuEnergyDrv.sys)",
                                        "Description":  "Windows GPU energy monitoring. Disabling may affect power telemetry and laptop efficiency. Separate from the graphics driver and not already present in this APBOptimizer catalog.",
                                        "Type":  "Toggle",
                                        "ParentGroup":  "WPFDriverGroupOptional",
                                        "category":  "z__Advanced Tweaks - CAUTION",
                                        "panel":  "1",
                                        "driver":  {
                                                       "Name":  "GpuEnergyDrv"
                                                   },
                                        "InvokeScript":  [
                                                             "Set-WinUtilOptionalDriver -Name GpuEnergyDrv -Mode Disable"
                                                         ],
                                        "UndoScript":  [
                                                           "Set-WinUtilOptionalDriver -Name GpuEnergyDrv -Mode Restore"
                                                       ]
                                    },
    "WPFToggleDriverIObitUnlocker":  {
                                         "Content":  "IObit Unlocker driver (IObitUnlocker.sys)",
                                         "Description":  "Third-party IObit Unlocker driver. If you use its locked-file functions, disabling the driver can break them. Prefer uninstalling the unused application. Only available if the exact IObitUnlocker driver service exists.",
                                         "Type":  "Toggle",
                                         "ParentGroup":  "WPFDriverGroupOptional",
                                         "category":  "z__Advanced Tweaks - CAUTION",
                                         "panel":  "1",
                                         "driver":  {
                                                        "Name":  "IObitUnlocker"
                                                    },
                                         "InvokeScript":  [
                                                              "Set-WinUtilOptionalDriver -Name IObitUnlocker -Mode Disable"
                                                          ],
                                         "UndoScript":  [
                                                            "Set-WinUtilOptionalDriver -Name IObitUnlocker -Mode Restore"
                                                        ]
                                     },
    "WPFTweaksDisableUCPD":  {
                                 "Content":  "UCPD.sys and UCPD velocity - Disable",
                                 "Description":  "Separate advanced tweak for the UserChoice Protection Driver. Protects browser/PDF default associations against unauthorized changes. Applying saves the original UCPD startup type and UCPD velocity scheduled-task state, then disables their next-boot startup. Undo restores both previous states. The task is disabled, not deleted. A reboot is required. Windows updates may reactivate the driver.",
                                 "category":  "z__Advanced Tweaks - CAUTION",
                                 "panel":  "1",
                                 "driver":  {
                                                "Name":  "UCPD"
                                            },
                                 "InvokeScript":  [
                                                      "Set-WinUtilOptionalDriver -Name UCPD -Mode Disable"
                                                  ],
                                 "UndoScript":  [
                                                    "Set-WinUtilOptionalDriver -Name UCPD -Mode Restore"
                                                ],
                                 "link":  "https://www.elevenforum.com/t/enable-or-disable-userchoice-protection-driver-ucpd-in-windows-11-and-10.24267/"
                             },
    "WPFToggleServiceWdiSystemHost":  {
                                          "Content":  "Diagnostic System Host (WdiSystemHost)",
                                          "Description":  "Used by Windows Diagnostic Policy Service for system-level troubleshooting. Disabling it prevents some diagnostics from running. Undo restores Manual startup.",
                                          "Type":  "Toggle",
                                          "ParentGroup":  "WPFServiceGroupDiagnostics",
                                          "category":  "z__Advanced Tweaks - CAUTION",
                                          "panel":  "1",
                                          "service":  [
                                                          {
                                                              "Name":  "WdiSystemHost",
                                                              "StartupType":  "Disabled",
                                                              "OriginalType":  "Manual",
                                                              "ForceStartup":  true
                                                          }
                                                      ],
                                          "InvokeScript":  [
                                                               "if ((Get-Service -Name WdiSystemHost -ErrorAction Stop).Status -ne \u0027Stopped\u0027) { Stop-Service -Name WdiSystemHost -ErrorAction Stop }"
                                                           ],
                                          "link":  "https://learn.microsoft.com/en-us/windows/iot/iot-enterprise/optimize/services"
                                      },
    "WPFToggleServiceWdiServiceHost":  {
                                           "Content":  "Diagnostic Service Host (WdiServiceHost)",
                                           "Description":  "Hosts diagnostics in the Local Service context. Disabling it prevents dependent troubleshooting from working. Undo restores Manual startup.",
                                           "Type":  "Toggle",
                                           "ParentGroup":  "WPFServiceGroupDiagnostics",
                                           "category":  "z__Advanced Tweaks - CAUTION",
                                           "panel":  "1",
                                           "service":  [
                                                           {
                                                               "Name":  "WdiServiceHost",
                                                               "StartupType":  "Disabled",
                                                               "OriginalType":  "Manual",
                                                               "ForceStartup":  true
                                                           }
                                                       ],
                                           "InvokeScript":  [
                                                                "if ((Get-Service -Name WdiServiceHost -ErrorAction Stop).Status -ne \u0027Stopped\u0027) { Stop-Service -Name WdiServiceHost -ErrorAction Stop }"
                                                            ],
                                           "link":  "https://learn.microsoft.com/en-us/windows/iot/iot-enterprise/optimize/services"
                                       },
    "WPFToggleServiceDiagTrack":  {
                                      "Content":  "Connected User Experiences (DiagTrack)",
                                      "Description":  "Windows diagnostics and telemetry service. May already be disabled by Telemetry - Disable; Undo restores Automatic startup.",
                                      "Type":  "Toggle",
                                      "ParentGroup":  "WPFServiceGroupDiagnostics",
                                      "category":  "z__Advanced Tweaks - CAUTION",
                                      "panel":  "1",
                                      "service":  [
                                                      {
                                                          "Name":  "DiagTrack",
                                                          "StartupType":  "Disabled",
                                                          "OriginalType":  "Automatic",
                                                          "ForceStartup":  true
                                                      }
                                                  ],
                                      "InvokeScript":  [
                                                           "if ((Get-Service -Name DiagTrack -ErrorAction Stop).Status -ne \u0027Stopped\u0027) { Stop-Service -Name DiagTrack -ErrorAction Stop }"
                                                       ],
                                      "UndoScript":  [
                                                         "if ((Get-Service -Name DiagTrack -ErrorAction Stop).Status -ne \u0027Running\u0027) { Start-Service -Name DiagTrack -ErrorAction Stop }"
                                                     ],
                                      "link":  "https://learn.microsoft.com/en-us/windows/iot/iot-enterprise/optimize/services"
                                  },
    "WPFToggleServiceShellHWDetection":  {
                                             "Content":  "Shell Hardware Detection (ShellHWDetection)",
                                             "Description":  "Provides AutoPlay notifications when media or devices are connected. Disabling removes those notifications and can affect device-related features. Undo restores Automatic startup.",
                                             "Type":  "Toggle",
                                             "ParentGroup":  "WPFServiceGroupUseless",
                                             "category":  "z__Advanced Tweaks - CAUTION",
                                             "panel":  "1",
                                             "service":  [
                                                             {
                                                                 "Name":  "ShellHWDetection",
                                                                 "StartupType":  "Disabled",
                                                                 "OriginalType":  "Automatic",
                                                                 "ForceStartup":  true
                                                             }
                                                         ],
                                             "InvokeScript":  [
                                                                  "if ((Get-Service -Name ShellHWDetection -ErrorAction Stop).Status -ne \u0027Stopped\u0027) { Stop-Service -Name ShellHWDetection -ErrorAction Stop }"
                                                              ],
                                             "UndoScript":  [
                                                                "if ((Get-Service -Name ShellHWDetection -ErrorAction Stop).Status -ne \u0027Running\u0027) { Start-Service -Name ShellHWDetection -ErrorAction Stop }"
                                                            ],
                                             "link":  "https://learn.microsoft.com/en-us/windows/iot/iot-enterprise/optimize/services"
                                         },
    "WPFToggleServiceDPS":  {
                                "Content":  "Diagnostic Policy Service (DPS)",
                                "Description":  "Required for Windows problem detection and troubleshooting. Microsoft recommends keeping it enabled. Disabling can break diagnostics; Undo restores Automatic startup.",
                                "Type":  "Toggle",
                                "ParentGroup":  "WPFServiceGroupDiagnostics",
                                "category":  "z__Advanced Tweaks - CAUTION",
                                "panel":  "1",
                                "service":  [
                                                {
                                                    "Name":  "DPS",
                                                    "StartupType":  "Disabled",
                                                    "OriginalType":  "Automatic",
                                                    "ForceStartup":  true
                                                }
                                            ],
                                "InvokeScript":  [
                                                     "if ((Get-Service -Name DPS -ErrorAction Stop).Status -ne \u0027Stopped\u0027) { Stop-Service -Name DPS -ErrorAction Stop }"
                                                 ],
                                "UndoScript":  [
                                                   "if ((Get-Service -Name DPS -ErrorAction Stop).Status -ne \u0027Running\u0027) { Start-Service -Name DPS -ErrorAction Stop }"
                                               ],
                                "link":  "https://learn.microsoft.com/en-us/windows/iot/iot-enterprise/optimize/services"
                            },
    "WPFToggleServiceWMPNetworkSvc":  {
                                          "Content":  "Media Player Network Sharing (WMPNetworkSvc)",
                                          "Description":  "Shares Windows Media Player libraries with networked players and devices. Disabling removes that sharing. Undo restores Manual startup; this service may not exist on some Windows installations.",
                                          "Type":  "Toggle",
                                          "ParentGroup":  "WPFServiceGroupUseless",
                                          "category":  "z__Advanced Tweaks - CAUTION",
                                          "panel":  "1",
                                          "service":  [
                                                          {
                                                              "Name":  "WMPNetworkSvc",
                                                              "StartupType":  "Disabled",
                                                              "OriginalType":  "Manual",
                                                              "ForceStartup":  true
                                                          }
                                                      ],
                                          "InvokeScript":  [
                                                               "if ((Get-Service -Name WMPNetworkSvc -ErrorAction Stop).Status -ne \u0027Stopped\u0027) { Stop-Service -Name WMPNetworkSvc -ErrorAction Stop }"
                                                           ],
                                          "link":  "https://learn.microsoft.com/en-us/windows/iot/iot-enterprise/optimize/services"
                                      },
    "WPFToggleServicewisvc":  {
                                  "Content":  "Windows Insider Service (wisvc)",
                                  "Description":  "Used by the Windows Insider Program for preview builds. Disabling can interfere with Insider functionality. Undo restores Manual startup; the service may be absent.",
                                  "Type":  "Toggle",
                                  "ParentGroup":  "WPFServiceGroupUseless",
                                  "category":  "z__Advanced Tweaks - CAUTION",
                                  "panel":  "1",
                                  "service":  [
                                                  {
                                                      "Name":  "wisvc",
                                                      "StartupType":  "Disabled",
                                                      "OriginalType":  "Manual",
                                                      "ForceStartup":  true
                                                  }
                                              ],
                                  "InvokeScript":  [
                                                       "if ((Get-Service -Name wisvc -ErrorAction Stop).Status -ne \u0027Stopped\u0027) { Stop-Service -Name wisvc -ErrorAction Stop }"
                                                   ],
                                  "link":  "https://learn.microsoft.com/en-us/windows/iot/iot-enterprise/optimize/services"
                              },
    "WPFToggleServiceWerSvc":  {
                                   "Content":  "Windows Error Reporting (WerSvc)",
                                   "Description":  "Collects and reports Windows application and system failures. Disabling can reduce error reporting and diagnostic information. Undo restores Manual startup.",
                                   "Type":  "Toggle",
                                   "ParentGroup":  "WPFServiceGroupDiagnostics",
                                   "category":  "z__Advanced Tweaks - CAUTION",
                                   "panel":  "1",
                                   "service":  [
                                                   {
                                                       "Name":  "WerSvc",
                                                       "StartupType":  "Disabled",
                                                       "OriginalType":  "Manual",
                                                       "ForceStartup":  true
                                                   }
                                               ],
                                   "InvokeScript":  [
                                                        "if ((Get-Service -Name WerSvc -ErrorAction Stop).Status -ne \u0027Stopped\u0027) { Stop-Service -Name WerSvc -ErrorAction Stop }"
                                                    ],
                                   "link":  "https://learn.microsoft.com/en-us/windows/iot/iot-enterprise/optimize/services"
                               },
    "WPFToggleServiceFontCache3000":  {
                                          "Content":  "WPF Font Cache (FontCache3.0.0.0)",
                                          "Description":  "Caches fonts for older Windows Presentation Foundation applications. Disabling may slow some .NET/WPF applications; often absent on newer Windows. Undo restores Manual startup.",
                                          "Type":  "Toggle",
                                          "ParentGroup":  "WPFServiceGroupUseless",
                                          "category":  "z__Advanced Tweaks - CAUTION",
                                          "panel":  "1",
                                          "service":  [
                                                          {
                                                              "Name":  "FontCache3.0.0.0",
                                                              "StartupType":  "Disabled",
                                                              "OriginalType":  "Manual",
                                                              "ForceStartup":  true
                                                          }
                                                      ],
                                          "InvokeScript":  [
                                                               "if ((Get-Service -Name \u0027FontCache3.0.0.0\u0027 -ErrorAction Stop).Status -ne \u0027Stopped\u0027) { Stop-Service -Name \u0027FontCache3.0.0.0\u0027 -ErrorAction Stop }"
                                                           ],
                                          "link":  "https://learn.microsoft.com/en-us/windows/iot/iot-enterprise/optimize/services"
                                      },
    "WPFToggleServiceRetailDemo":  {
                                       "Content":  "Retail Demo Service (RetailDemo)",
                                       "Description":  "Used to display retail demonstration experiences on store devices. Disabling prevents retail demo functionality. Undo restores Manual startup.",
                                       "Type":  "Toggle",
                                       "ParentGroup":  "WPFServiceGroupUseless",
                                       "category":  "z__Advanced Tweaks - CAUTION",
                                       "panel":  "1",
                                       "service":  [
                                                       {
                                                           "Name":  "RetailDemo",
                                                           "StartupType":  "Disabled",
                                                           "OriginalType":  "Manual",
                                                           "ForceStartup":  true
                                                       }
                                                   ],
                                       "InvokeScript":  [
                                                            "if ((Get-Service -Name RetailDemo -ErrorAction Stop).Status -ne \u0027Stopped\u0027) { Stop-Service -Name RetailDemo -ErrorAction Stop }"
                                                        ],
                                       "link":  "https://learn.microsoft.com/en-us/windows-hardware/customize/desktop/retail-demo-experience"
                                   },
    "WPFToggleServiceDiagnosticsHub":  {
                                           "Content":  "Diagnostics Hub Collector (diagnosticshub.standardcollector.service)",
                                           "Description":  "Collects Event Tracing for Windows (ETW) events for diagnostic and development tools. Disabling can interfere with diagnostic traces and profiling. Undo restores Manual startup.",
                                           "Type":  "Toggle",
                                           "ParentGroup":  "WPFServiceGroupDiagnostics",
                                           "category":  "z__Advanced Tweaks - CAUTION",
                                           "panel":  "1",
                                           "service":  [
                                                           {
                                                               "Name":  "diagnosticshub.standardcollector.service",
                                                               "StartupType":  "Disabled",
                                                               "OriginalType":  "Manual",
                                                               "ForceStartup":  true
                                                           }
                                                       ],
                                           "InvokeScript":  [
                                                                "if ((Get-Service -Name \u0027diagnosticshub.standardcollector.service\u0027 -ErrorAction Stop).Status -ne \u0027Stopped\u0027) { Stop-Service -Name \u0027diagnosticshub.standardcollector.service\u0027 -ErrorAction Stop }"
                                                            ],
                                           "link":  "https://learn.microsoft.com/en-us/windows-server/security/windows-services/security-guidelines-for-disabling-system-services-in-windows-server"
                                       },
    "WPFToggleServiceDmwappushservice":  {
                                             "Content":  "Device Management WAP Push (dmwappushservice)",
                                             "Description":  "Routes device management push messages. Disabling can interrupt MDM/Intune management and device enrollment. Undo restores Manual startup.",
                                             "Type":  "Toggle",
                                             "ParentGroup":  "WPFServiceGroupUseless",
                                             "category":  "z__Advanced Tweaks - CAUTION",
                                             "panel":  "1",
                                             "service":  [
                                                             {
                                                                 "Name":  "dmwappushservice",
                                                                 "StartupType":  "Disabled",
                                                                 "OriginalType":  "Manual",
                                                                 "ForceStartup":  true
                                                             }
                                                         ],
                                             "InvokeScript":  [
                                                                  "if ((Get-Service -Name dmwappushservice -ErrorAction Stop).Status -ne \u0027Stopped\u0027) { Stop-Service -Name dmwappushservice -ErrorAction Stop }"
                                                              ],
                                             "link":  "https://learn.microsoft.com/en-us/windows-server/security/windows-services/security-guidelines-for-disabling-system-services-in-windows-server"
                                         },
    "WPFToggleServiceWhesvc":  {
                                   "Content":  "Windows Health and Optimized Experiences (whesvc)",
                                   "Description":  "Monitors device health for optimized Windows experiences. Disabling may affect device health and optimization features; it is not present on every Windows version. Undo restores Automatic startup and starts the service.",
                                   "Type":  "Toggle",
                                   "ParentGroup":  "WPFServiceGroupUseless",
                                   "category":  "z__Advanced Tweaks - CAUTION",
                                   "panel":  "1",
                                   "service":  [
                                                   {
                                                       "Name":  "whesvc",
                                                       "StartupType":  "Disabled",
                                                       "OriginalType":  "Automatic",
                                                       "ForceStartup":  true
                                                   }
                                               ],
                                   "InvokeScript":  [
                                                        "if ((Get-Service -Name whesvc -ErrorAction Stop).Status -ne \u0027Stopped\u0027) { Stop-Service -Name whesvc -ErrorAction Stop }"
                                                    ],
                                   "UndoScript":  [
                                                      "if ((Get-Service -Name whesvc -ErrorAction Stop).Status -ne \u0027Running\u0027) { Start-Service -Name whesvc -ErrorAction Stop }"
                                                  ]
                               },
    "WPFToggleServiceNetTcpPortSharing":  {
                                              "Content":  "Net.TCP Port Sharing (NetTcpPortSharing)",
                                              "Description":  "Allows Windows Communication Foundation applications to share TCP ports. This service is disabled on Windows by default; if already disabled, its checkbox starts checked. Unchecking sets Manual startup without starting it (required when using WCF port sharing).",
                                              "Type":  "Toggle",
                                              "ParentGroup":  "WPFServiceGroupUseless",
                                              "category":  "z__Advanced Tweaks - CAUTION",
                                              "panel":  "1",
                                              "service":  [
                                                              {
                                                                  "Name":  "NetTcpPortSharing",
                                                                  "StartupType":  "Disabled",
                                                                  "OriginalType":  "Manual",
                                                                  "ForceStartup":  true
                                                              }
                                                          ],
                                              "InvokeScript":  [
                                                                   "if ((Get-Service -Name NetTcpPortSharing -ErrorAction Stop).Status -ne \u0027Stopped\u0027) { Stop-Service -Name NetTcpPortSharing -ErrorAction Stop }"
                                                               ],
                                              "link":  "https://learn.microsoft.com/en-us/dotnet/framework/wcf/feature-details/how-to-enable-the-net-tcp-port-sharing-service"
                                          },
    "WPFTweaksDisableWindowsSearch":  {
                                          "Content":  "Windows Search Indexing - Disable",
                                          "Description":  "Stops the Windows Search (WSearch) service and disables its startup. This reduces background indexing, but can slow or break file, Start menu and Outlook searches. Undo restores Automatic (Delayed Start) and starts the service.",
                                          "category":  "z__Advanced Tweaks - CAUTION",
                                          "panel":  "1",
                                          "service":  [
                                                          {
                                                              "Name":  "WSearch",
                                                              "StartupType":  "Disabled",
                                                              "OriginalType":  "AutomaticDelayedStart",
                                                              "ForceStartup":  true
                                                          }
                                                      ],
                                          "InvokeScript":  [
                                                               "if ((Get-Service -Name WSearch -ErrorAction Stop).Status -ne \u0027Stopped\u0027) { Stop-Service -Name WSearch -ErrorAction Stop }"
                                                           ],
                                          "UndoScript":  [
                                                             "if ((Get-Service -Name WSearch -ErrorAction Stop).Status -ne \u0027Running\u0027) { Start-Service -Name WSearch -ErrorAction Stop }"
                                                         ],
                                          "link":  "https://learn.microsoft.com/en-us/troubleshoot/windows-client/shell-experience/windows-search-performance-issues"
                                      },
    "WPFTweaksDisableSearchWebView2":  {
                                           "Content":  "Start Search WebView2 Processes - Disable [restart required]",
                                           "Description":  "Stops SearchHost.exe from keeping msedgewebview2.exe processes running in the background. Writes the same feature override as \u0027vivetool /disable /id:37926450\u0027 (SearchWebView2) directly to the registry, without running ViVeTool. Also turns off the new Start menu search interface. Microsoft can rename or remove this feature in an update, and then the override has no effect. Requires a restart. Undo removes the override.",
                                           "category":  "z__Advanced Tweaks - CAUTION",
                                           "panel":  "1",
                                           "registry":  [
                                                            {
                                                                "Path":  "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\FeatureManagement\\Overrides\\8\\1694661260",
                                                                "Name":  "EnabledState",
                                                                "Value":  "1",
                                                                "Type":  "DWord",
                                                                "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                            },
                                                            {
                                                                "Path":  "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\FeatureManagement\\Overrides\\8\\1694661260",
                                                                "Name":  "EnabledStateOptions",
                                                                "Value":  "0",
                                                                "Type":  "DWord",
                                                                "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                            },
                                                            {
                                                                "Path":  "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\FeatureManagement\\Overrides\\8\\1694661260",
                                                                "Name":  "Variant",
                                                                "Value":  "0",
                                                                "Type":  "DWord",
                                                                "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                            },
                                                            {
                                                                "Path":  "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\FeatureManagement\\Overrides\\8\\1694661260",
                                                                "Name":  "VariantPayload",
                                                                "Value":  "0",
                                                                "Type":  "DWord",
                                                                "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                            },
                                                            {
                                                                "Path":  "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\FeatureManagement\\Overrides\\8\\1694661260",
                                                                "Name":  "VariantPayloadKind",
                                                                "Value":  "0",
                                                                "Type":  "DWord",
                                                                "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                            }
                                                        ],
                                           "UndoScript":  [
                                                              "# ViVeTool /reset deletes the whole override key; remove it once its values are gone.\n      $overrideKey = \u0027HKLM:\\SYSTEM\\CurrentControlSet\\Control\\FeatureManagement\\Overrides\\8\\1694661260\u0027\n      if ((Test-Path -LiteralPath $overrideKey) -and @((Get-Item -LiteralPath $overrideKey).GetValueNames()).Count -eq 0) { Remove-Item -LiteralPath $overrideKey -ErrorAction Stop }"
                                                          ],
                                           "link":  "https://github.com/thebookisclosed/ViVe"
                                       },
    "WPFTaskGroupTelemetry":  {
                                  "Content":  "Disable Optional Scheduled Tasks",
                                  "Description":  "Choose optional telemetry, compatibility, Windows Media Sharing and Firefox tasks in the dropdown. Marking or unmarking only stages changes; click Apply Tweaks to disable selected tasks or restore unchecked tasks previously managed by APBOptimizer. The master checkbox selects all manageable tasks. Missing tasks are hidden, and tasks disabled outside APBOptimizer are protected. Each task has an independent backup for Undo.",
                                  "Type":  "TaskGroup",
                                  "category":  "z__Advanced Tweaks - CAUTION",
                                  "panel":  "1",
                                  "Children":  [
                                                   "WPFToggleTaskCompatibilityAppraiser",
                                                   "WPFToggleTaskProgramDataUpdater",
                                                   "WPFToggleTaskConsolidator",
                                                   "WPFToggleTaskUsbCeip",
                                                   "WPFToggleTaskKernelCeip",
                                                   "WPFToggleTaskCompatibilityAppraiserExp",
                                                   "WPFToggleTaskWindowsMediaSharing",
                                                   "WPFToggleTaskUsageDataReporting",
                                                   "WPFToggleTaskSustainabilityTelemetry",
                                                   "WPFToggleTaskFirefoxDefaultBrowserAgent"
                                               ],
                                  "link":  "https://learn.microsoft.com/en-us/powershell/module/scheduledtasks/disable-scheduledtask"
                              },
    "WPFToggleTaskCompatibilityAppraiser":  {
                                                "Content":  "Microsoft Compatibility Appraiser",
                                                "Description":  "Collects application and device compatibility information. Disabling it can affect upgrade compatibility assessments. Undo restores the previously enabled state.",
                                                "Type":  "Toggle",
                                                "ParentGroup":  "WPFTaskGroupTelemetry",
                                                "category":  "z__Advanced Tweaks - CAUTION",
                                                "panel":  "1",
                                                "scheduledTask":  {
                                                                      "Name":  "Microsoft Compatibility Appraiser"
                                                                  },
                                                "InvokeScript":  [
                                                                     "Set-WinUtilTelemetryTask -Name \u0027Microsoft Compatibility Appraiser\u0027 -Mode Disable"
                                                                 ],
                                                "UndoScript":  [
                                                                   "Set-WinUtilTelemetryTask -Name \u0027Microsoft Compatibility Appraiser\u0027 -Mode Restore"
                                                               ],
                                                "link":  "https://learn.microsoft.com/en-us/powershell/module/scheduledtasks/disable-scheduledtask"
                                            },
    "WPFToggleTaskProgramDataUpdater":  {
                                            "Content":  "ProgramDataUpdater",
                                            "Description":  "Updates program inventory data for application compatibility and diagnostics. Undo restores its original state.",
                                            "Type":  "Toggle",
                                            "ParentGroup":  "WPFTaskGroupTelemetry",
                                            "category":  "z__Advanced Tweaks - CAUTION",
                                            "panel":  "1",
                                            "scheduledTask":  {
                                                                  "Name":  "ProgramDataUpdater"
                                                              },
                                            "InvokeScript":  [
                                                                 "Set-WinUtilTelemetryTask -Name ProgramDataUpdater -Mode Disable"
                                                             ],
                                            "UndoScript":  [
                                                               "Set-WinUtilTelemetryTask -Name ProgramDataUpdater -Mode Restore"
                                                           ],
                                            "link":  "https://learn.microsoft.com/en-us/powershell/module/scheduledtasks/disable-scheduledtask"
                                        },
    "WPFToggleTaskConsolidator":  {
                                      "Content":  "Consolidator (CEIP)",
                                      "Description":  "Runs the Customer Experience Improvement Program data consolidation task. Undo restores its original state.",
                                      "Type":  "Toggle",
                                      "ParentGroup":  "WPFTaskGroupTelemetry",
                                      "category":  "z__Advanced Tweaks - CAUTION",
                                      "panel":  "1",
                                      "scheduledTask":  {
                                                            "Name":  "Consolidator"
                                                        },
                                      "InvokeScript":  [
                                                           "Set-WinUtilTelemetryTask -Name Consolidator -Mode Disable"
                                                       ],
                                      "UndoScript":  [
                                                         "Set-WinUtilTelemetryTask -Name Consolidator -Mode Restore"
                                                     ],
                                      "link":  "https://learn.microsoft.com/en-us/powershell/module/scheduledtasks/disable-scheduledtask"
                                  },
    "WPFToggleTaskUsbCeip":  {
                                 "Content":  "UsbCeip (CEIP USB)",
                                 "Description":  "Collects optional USB device usage diagnostics. Undo restores its original state.",
                                 "Type":  "Toggle",
                                 "ParentGroup":  "WPFTaskGroupTelemetry",
                                 "category":  "z__Advanced Tweaks - CAUTION",
                                 "panel":  "1",
                                 "scheduledTask":  {
                                                       "Name":  "UsbCeip"
                                                   },
                                 "InvokeScript":  [
                                                      "Set-WinUtilTelemetryTask -Name UsbCeip -Mode Disable"
                                                  ],
                                 "UndoScript":  [
                                                    "Set-WinUtilTelemetryTask -Name UsbCeip -Mode Restore"
                                                ],
                                 "link":  "https://learn.microsoft.com/en-us/powershell/module/scheduledtasks/disable-scheduledtask"
                             },
    "WPFToggleTaskKernelCeip":  {
                                    "Content":  "KernelCeipTask (CEIP kernel)",
                                    "Description":  "Collects optional Windows kernel experience data. Undo restores its original state.",
                                    "Type":  "Toggle",
                                    "ParentGroup":  "WPFTaskGroupTelemetry",
                                    "category":  "z__Advanced Tweaks - CAUTION",
                                    "panel":  "1",
                                    "scheduledTask":  {
                                                          "Name":  "KernelCeipTask"
                                                      },
                                    "InvokeScript":  [
                                                         "Set-WinUtilTelemetryTask -Name KernelCeipTask -Mode Disable"
                                                     ],
                                    "UndoScript":  [
                                                       "Set-WinUtilTelemetryTask -Name KernelCeipTask -Mode Restore"
                                                   ],
                                    "link":  "https://learn.microsoft.com/en-us/powershell/module/scheduledtasks/disable-scheduledtask"
                                },
    "WPFToggleTaskCompatibilityAppraiserExp":  {
                                                   "Content":  "Microsoft Compatibility Appraiser Exp",
                                                   "Description":  "Additional app compatibility telemetry task found on newer Windows installations. Disabling it may affect Windows upgrade compatibility assessments. Undo restores its previous state.",
                                                   "Type":  "Toggle",
                                                   "ParentGroup":  "WPFTaskGroupTelemetry",
                                                   "category":  "z__Advanced Tweaks - CAUTION",
                                                   "panel":  "1",
                                                   "scheduledTask":  {
                                                                         "Name":  "Microsoft Compatibility Appraiser Exp"
                                                                     },
                                                   "InvokeScript":  [
                                                                        "Set-WinUtilTelemetryTask -Name \u0027Microsoft Compatibility Appraiser Exp\u0027 -Mode Disable"
                                                                    ],
                                                   "UndoScript":  [
                                                                      "Set-WinUtilTelemetryTask -Name \u0027Microsoft Compatibility Appraiser Exp\u0027 -Mode Restore"
                                                                  ],
                                                   "link":  "https://learn.microsoft.com/en-us/powershell/module/scheduledtasks/disable-scheduledtask"
                                               },
    "WPFToggleTaskWindowsMediaSharing":  {
                                             "Content":  "Windows Media Sharing - UpdateLibrary",
                                             "Description":  "Updates the Windows Media Player network-sharing library. Optional when you do not share media to devices on the local network; disabling may affect media library updates.",
                                             "Type":  "Toggle",
                                             "ParentGroup":  "WPFTaskGroupTelemetry",
                                             "category":  "z__Advanced Tweaks - CAUTION",
                                             "panel":  "1",
                                             "scheduledTask":  {
                                                                   "Name":  "UpdateLibrary"
                                                               },
                                             "InvokeScript":  [
                                                                  "Set-WinUtilTelemetryTask -Name UpdateLibrary -Mode Disable"
                                                              ],
                                             "UndoScript":  [
                                                                "Set-WinUtilTelemetryTask -Name UpdateLibrary -Mode Restore"
                                                            ],
                                             "link":  "https://learn.microsoft.com/en-us/powershell/module/scheduledtasks/disable-scheduledtask"
                                         },
    "WPFToggleTaskUsageDataReporting":  {
                                            "Content":  "Flighting - UsageDataReporting",
                                            "Description":  "Reports Windows FeatureConfig usage data. Disabling may affect feature usage reporting or internal feature configuration. Undo restores the previous state.",
                                            "Type":  "Toggle",
                                            "ParentGroup":  "WPFTaskGroupTelemetry",
                                            "category":  "z__Advanced Tweaks - CAUTION",
                                            "panel":  "1",
                                            "scheduledTask":  {
                                                                  "Name":  "UsageDataReporting"
                                                              },
                                            "InvokeScript":  [
                                                                 "Set-WinUtilTelemetryTask -Name UsageDataReporting -Mode Disable"
                                                             ],
                                            "UndoScript":  [
                                                               "Set-WinUtilTelemetryTask -Name UsageDataReporting -Mode Restore"
                                                           ],
                                            "link":  "https://learn.microsoft.com/en-us/powershell/module/scheduledtasks/disable-scheduledtask"
                                        },
    "WPFToggleTaskSustainabilityTelemetry":  {
                                                 "Content":  "SustainabilityTelemetry",
                                                 "Description":  "Reports Windows sustainability-related telemetry. Disabling may stop sustainability data collection. Does not disable PowerGridForecastTask.",
                                                 "Type":  "Toggle",
                                                 "ParentGroup":  "WPFTaskGroupTelemetry",
                                                 "category":  "z__Advanced Tweaks - CAUTION",
                                                 "panel":  "1",
                                                 "scheduledTask":  {
                                                                       "Name":  "SustainabilityTelemetry"
                                                                   },
                                                 "InvokeScript":  [
                                                                      "Set-WinUtilTelemetryTask -Name SustainabilityTelemetry -Mode Disable"
                                                                  ],
                                                 "UndoScript":  [
                                                                    "Set-WinUtilTelemetryTask -Name SustainabilityTelemetry -Mode Restore"
                                                                ],
                                                 "link":  "https://learn.microsoft.com/en-us/powershell/module/scheduledtasks/disable-scheduledtask"
                                             },
    "WPFToggleTaskFirefoxDefaultBrowserAgent":  {
                                                    "Content":  "Firefox Default Browser Agent",
                                                    "Description":  "Optional Firefox task that checks default-browser changes. Matches only Mozilla\u0027s Firefox Default Browser Agent task(s) with a hexadecimal identifier; exact original states are saved for Undo. It does not disable Firefox updates.",
                                                    "Type":  "Toggle",
                                                    "ParentGroup":  "WPFTaskGroupTelemetry",
                                                    "category":  "z__Advanced Tweaks - CAUTION",
                                                    "panel":  "1",
                                                    "scheduledTask":  {
                                                                          "Name":  "Firefox Default Browser Agent"
                                                                      },
                                                    "InvokeScript":  [
                                                                         "Set-WinUtilTelemetryTask -Name \u0027Firefox Default Browser Agent\u0027 -Mode Disable"
                                                                     ],
                                                    "UndoScript":  [
                                                                       "Set-WinUtilTelemetryTask -Name \u0027Firefox Default Browser Agent\u0027 -Mode Restore"
                                                                   ],
                                                    "link":  "https://learn.microsoft.com/en-us/powershell/module/scheduledtasks/disable-scheduledtask"
                                                },
    "WPFTweaksDisableTelemetryTasks":  {
                                           "Content":  "Optional Telemetry Scheduled Tasks - Legacy",
                                           "Description":  "Compatibility-only entry for older saved APBOptimizer configurations. The visible TaskGroup replaces this checkbox.",
                                           "ParentGroup":  "WPFTaskGroupTelemetry",
                                           "category":  "z__Advanced Tweaks - CAUTION",
                                           "panel":  "1",
                                           "ScheduledTaskCleanup":  true,
                                           "InvokeScript":  [
                                                                "Set-WinUtilTelemetryTasks -Mode Disable"
                                                            ],
                                           "UndoScript":  [
                                                              "Set-WinUtilTelemetryTasks -Mode Restore"
                                                          ],
                                           "link":  "https://learn.microsoft.com/en-us/powershell/module/scheduledtasks/disable-scheduledtask"
                                       },
    "WPFTweaksPauseWindows2099":  {
                                      "Content":  "Windows Update - Pause until 2099 (experimental)",
                                      "Description":  "Experimental registry-only pause through August 17, 2099. Microsoft officially supports pauses of up to 35 days, so this date may be ignored or reset. It is recommended to pause updates for 7 days in Windows Settings first, but this is not required. Applying saves the previous registry values; Undo restores them. It does not disable Windows services, scheduled tasks or rename protected DLLs. Blocks security updates if Windows honors the pause.",
                                      "category":  "z__Advanced Tweaks - CAUTION",
                                      "panel":  "1",
                                      "InvokeScript":  [
                                                           "Set-WinUtilWindowsPause -Mode Pause"
                                                       ],
                                      "UndoScript":  [
                                                         "Set-WinUtilWindowsPause -Mode Restore"
                                                     ],
                                      "link":  "https://support.microsoft.com/windows/manage-updates-in-windows"
                                  },
    "WPFTweaksDisableMemoryIntegrity":  {
                                            "Content":  "Memory Integrity (HVCI) - Disable [restart required]",
                                            "Description":  "Advanced Windows 10/11 option. Disables Memory integrity (HVCI) by setting the DeviceGuard HypervisorEnforcedCodeIntegrity Enabled DWORD to 0, reducing protection against kernel malware. Requires administrator rights and a restart. It does NOT turn off all VBS, Credential Guard or the hypervisor. Policy-managed or UEFI-locked settings are protected; Windows may ignore or override registry changes. The original registry value (including an absent value) is backed up before applying and restored with Undo Selected Tweaks. Use Windows Security \u003e Device security \u003e Core isolation for the recommended manual method. Performance gains vary by hardware and game; none are guaranteed.",
                                            "category":  "z__Advanced Tweaks - CAUTION",
                                            "panel":  "1",
                                            "InvokeScript":  [
                                                                 "Set-WinUtilMemoryIntegrity -Mode Disable"
                                                             ],
                                            "UndoScript":  [
                                                               "Set-WinUtilMemoryIntegrity -Mode Restore"
                                                           ],
                                            "link":  "https://learn.microsoft.com/en-us/windows/security/hardware-security/enable-virtualization-based-protection-of-code-integrity"
                                        },
    "WPFTweaksDisablePowerThrottling":  {
                                            "Content":  "Power Throttling - Disable [restart recommended]",
                                            "Description":  "Windows 10/11 power-management option. Sets HKLM\\SYSTEM\\CurrentControlSet\\Control\\Power\\PowerThrottling\\PowerThrottlingOff (REG_DWORD) to 1 to turn off Windows process power throttling. It can help workloads that Windows throttles in the background, but usually does not improve foreground game FPS. Disabling energy-saving behavior may increase battery drain, power draw, temperature and fan noise. Requires administrator rights; a restart is recommended. Does not change the power plan, CPU limits or other power settings. Saves the exact original DWORD (including when absent) so Undo Selected Tweaks can restore it. A managed Windows policy may reapply this setting.",
                                            "category":  "z__Advanced Tweaks - CAUTION",
                                            "panel":  "1",
                                            "InvokeScript":  [
                                                                 "Set-WinUtilPowerThrottling -Mode Disable"
                                                             ],
                                            "UndoScript":  [
                                                               "Set-WinUtilPowerThrottling -Mode Restore"
                                                           ],
                                            "link":  "https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-admx-power#powerthrottlingturnoff"
                                        },
    "WPFTweaksDisableDevicePowerSaving":  {
                                              "Content":  "USB Selective Suspend \u0026 PCIe Link State - Disable",
                                              "Description":  "Windows 10/11 power plan option. Uses powercfg to set USB selective suspend and PCI Express Link State Power Management (ASPM) to Off for the plugged-in (AC) setting of the active power plan, then reactivates the plan. It can reduce USB mouse, controller or audio dropouts and PCIe wake-up latency; performance gains are not guaranteed. Battery (DC) values and other power plans are not changed. Power draw and idle temperature may increase slightly. Requires administrator rights; no restart needed. Saves the original AC values and the plan GUID so Undo Selected Tweaks can restore them.",
                                              "category":  "z__Advanced Tweaks - CAUTION",
                                              "panel":  "1",
                                              "InvokeScript":  [
                                                                   "Set-WinUtilDevicePowerSaving -Mode Disable"
                                                               ],
                                              "UndoScript":  [
                                                                 "Set-WinUtilDevicePowerSaving -Mode Restore"
                                                             ],
                                              "link":  "https://learn.microsoft.com/en-us/windows-hardware/customize/power-settings/usb-settings-usb-selective-suspend-setting"
                                          },
    "WPFTweaksDisableCPUMitigations":  {
                                           "Content":  "CPU Mitigations (Spectre/Meltdown) - Disable [restart required]",
                                           "Description":  "Advanced opt-in security setting for Windows 10/11. Follows shoober420/CPU_Mitigations.bat and Microsoft KB4073119: writes FeatureSettingsOverride=3 and FeatureSettingsOverrideMask=3 (REG_DWORD) under HKLM\\SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Memory Management. Disables operating-system speculative-execution mitigations including Spectre Variant 2 and Meltdown; other CPU, firmware and Windows protections are outside its scope. It substantially reduces security, especially on computers with untrusted applications or websites. Performance gains depend on CPU and workload and are not guaranteed. Requires administrator permissions and reboot. Saves both original registry values, including absent ones, so Undo Selected Tweaks can restore them. No third-party EXE or BAT is executed.",
                                           "category":  "z__Advanced Tweaks - CAUTION",
                                           "panel":  "1",
                                           "InvokeScript":  [
                                                                "Set-WinUtilCPUMitigations -Mode Disable"
                                                            ],
                                           "UndoScript":  [
                                                              "Set-WinUtilCPUMitigations -Mode Restore"
                                                          ],
                                           "link":  "https://support.microsoft.com/en-us/topic/kb4073119-windows-client-guidance-for-it-pros-to-protect-against-silicon-based-microarchitectural-and-speculative-execution-side-channel-vulnerabilities-35820a8a-ae13-1299-88cc-357f104f5b11"
                                       },
    "WPFTweaksBraveDebloat":  {
                                  "Content":  "Brave Browser - Debloat",
                                  "Description":  "Disables various annoyances like Brave Rewards, Leo AI, Crypto Wallet and VPN.",
                                  "category":  "z__Advanced Tweaks - CAUTION",
                                  "panel":  "1",
                                  "registry":  [
                                                   {
                                                       "Path":  "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
                                                       "Name":  "BraveRewardsDisabled",
                                                       "Value":  "1",
                                                       "Type":  "DWord",
                                                       "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                   },
                                                   {
                                                       "Path":  "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
                                                       "Name":  "BraveWalletDisabled",
                                                       "Value":  "1",
                                                       "Type":  "DWord",
                                                       "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                   },
                                                   {
                                                       "Path":  "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
                                                       "Name":  "BraveVPNDisabled",
                                                       "Value":  "1",
                                                       "Type":  "DWord",
                                                       "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                   },
                                                   {
                                                       "Path":  "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
                                                       "Name":  "BraveAIChatEnabled",
                                                       "Value":  "0",
                                                       "Type":  "DWord",
                                                       "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                   },
                                                   {
                                                       "Path":  "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
                                                       "Name":  "BraveStatsPingEnabled",
                                                       "Value":  "0",
                                                       "Type":  "DWord",
                                                       "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                   },
                                                   {
                                                       "Path":  "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
                                                       "Name":  "BraveNewsDisabled",
                                                       "Value":  "1",
                                                       "Type":  "DWord",
                                                       "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                   },
                                                   {
                                                       "Path":  "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
                                                       "Name":  "BraveTalkDisabled",
                                                       "Value":  "1",
                                                       "Type":  "DWord",
                                                       "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                   },
                                                   {
                                                       "Path":  "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
                                                       "Name":  "TorDisabled",
                                                       "Value":  "1",
                                                       "Type":  "DWord",
                                                       "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                   },
                                                   {
                                                       "Path":  "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
                                                       "Name":  "BraveP3AEnabled",
                                                       "Value":  "0",
                                                       "Type":  "DWord",
                                                       "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                   },
                                                   {
                                                       "Path":  "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
                                                       "Name":  "UrlKeyedAnonymizedDataCollectionEnabled",
                                                       "Value":  "0",
                                                       "Type":  "DWord",
                                                       "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                   },
                                                   {
                                                       "Path":  "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
                                                       "Name":  "SafeBrowsingExtendedReportingEnabled",
                                                       "Value":  "0",
                                                       "Type":  "DWord",
                                                       "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                   },
                                                   {
                                                       "Path":  "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
                                                       "Name":  "MetricsReportingEnabled",
                                                       "Value":  "0",
                                                       "Type":  "DWord",
                                                       "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                   }
                                               ],
                                  "link":  "https://winutil.christitus.com/code-reference/tweaks/z--advanced-tweaks---caution/bravedebloat"
                              },
    "WPFTweaksDisableWarningForUnsignedRdp":  {
                                                  "Content":  "RDP Unsigned File Warnings - Disable",
                                                  "Description":  "Disables warnings shown when launching unsigned RDP files introduced with the latest Windows 10 and 11 updates.",
                                                  "category":  "z__Advanced Tweaks - CAUTION",
                                                  "panel":  "1",
                                                  "registry":  [
                                                                   {
                                                                       "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows NT\\Terminal Services\\Client",
                                                                       "Name":  "RedirectionWarningDialogVersion",
                                                                       "Value":  "1",
                                                                       "Type":  "DWord",
                                                                       "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                                   },
                                                                   {
                                                                       "Path":  "HKCU:\\SOFTWARE\\Microsoft\\Terminal Server Client",
                                                                       "Name":  "RdpLaunchConsentAccepted",
                                                                       "Value":  "1",
                                                                       "Type":  "DWord",
                                                                       "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                                   }
                                                               ],
                                                  "link":  "https://winutil.christitus.com/code-reference/tweaks/z--advanced-tweaks---caution/disablewarningforunsignedrdp"
                                              },
    "WPFTweaksEdgeDebloat":  {
                                 "Content":  "Microsoft Edge - Debloat",
                                 "Description":  "Disables various telemetry options, popups, and other annoyances in Edge.",
                                 "category":  "z__Advanced Tweaks - CAUTION",
                                 "panel":  "1",
                                 "registry":  [
                                                  {
                                                      "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\EdgeUpdate",
                                                      "Name":  "CreateDesktopShortcutDefault",
                                                      "Value":  "0",
                                                      "Type":  "DWord",
                                                      "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                  },
                                                  {
                                                      "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
                                                      "Name":  "PersonalizationReportingEnabled",
                                                      "Value":  "0",
                                                      "Type":  "DWord",
                                                      "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                  },
                                                  {
                                                      "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge\\ExtensionInstallBlocklist",
                                                      "Name":  "1",
                                                      "Value":  "ofefcgjbeghpigppfmkologfjadafddi",
                                                      "Type":  "String",
                                                      "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                  },
                                                  {
                                                      "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
                                                      "Name":  "ShowRecommendationsEnabled",
                                                      "Value":  "0",
                                                      "Type":  "DWord",
                                                      "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                  },
                                                  {
                                                      "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
                                                      "Name":  "HideFirstRunExperience",
                                                      "Value":  "1",
                                                      "Type":  "DWord",
                                                      "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                  },
                                                  {
                                                      "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
                                                      "Name":  "UserFeedbackAllowed",
                                                      "Value":  "0",
                                                      "Type":  "DWord",
                                                      "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                  },
                                                  {
                                                      "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
                                                      "Name":  "ConfigureDoNotTrack",
                                                      "Value":  "1",
                                                      "Type":  "DWord",
                                                      "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                  },
                                                  {
                                                      "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
                                                      "Name":  "AlternateErrorPagesEnabled",
                                                      "Value":  "0",
                                                      "Type":  "DWord",
                                                      "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                  },
                                                  {
                                                      "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
                                                      "Name":  "EdgeCollectionsEnabled",
                                                      "Value":  "0",
                                                      "Type":  "DWord",
                                                      "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                  },
                                                  {
                                                      "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
                                                      "Name":  "EdgeShoppingAssistantEnabled",
                                                      "Value":  "0",
                                                      "Type":  "DWord",
                                                      "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                  },
                                                  {
                                                      "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
                                                      "Name":  "MicrosoftEdgeInsiderPromotionEnabled",
                                                      "Value":  "0",
                                                      "Type":  "DWord",
                                                      "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                  },
                                                  {
                                                      "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
                                                      "Name":  "ShowMicrosoftRewards",
                                                      "Value":  "0",
                                                      "Type":  "DWord",
                                                      "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                  },
                                                  {
                                                      "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
                                                      "Name":  "WebWidgetAllowed",
                                                      "Value":  "0",
                                                      "Type":  "DWord",
                                                      "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                  },
                                                  {
                                                      "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
                                                      "Name":  "DiagnosticData",
                                                      "Value":  "0",
                                                      "Type":  "DWord",
                                                      "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                  },
                                                  {
                                                      "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
                                                      "Name":  "EdgeAssetDeliveryServiceEnabled",
                                                      "Value":  "0",
                                                      "Type":  "DWord",
                                                      "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                  },
                                                  {
                                                      "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
                                                      "Name":  "WalletDonationEnabled",
                                                      "Value":  "0",
                                                      "Type":  "DWord",
                                                      "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                  },
                                                  {
                                                      "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
                                                      "Name":  "DefaultBrowserSettingsCampaignEnabled",
                                                      "Value":  "0",
                                                      "Type":  "DWord",
                                                      "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                  }
                                              ],
                                 "link":  "https://winutil.christitus.com/code-reference/tweaks/z--advanced-tweaks---caution/edgedebloat"
                             },
    "WPFTweaksConsumerFeatures":  {
                                      "Content":  "ConsumerFeatures - Disable",
                                      "Description":  "Stops promoted app installs and reduces app suggestions from Microsoft Store content.",
                                      "category":  "Essential Tweaks",
                                      "panel":  "1",
                                      "registry":  [
                                                       {
                                                           "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\CloudContent",
                                                           "Name":  "DisableWindowsConsumerFeatures",
                                                           "Value":  "1",
                                                           "Type":  "DWord",
                                                           "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                       }
                                                   ],
                                      "link":  "https://winutil.christitus.com/code-reference/tweaks/essential-tweaks/consumerfeatures"
                                  },
    "WPFTweaksTelemetry":  {
                               "Content":  "Telemetry - Disable",
                               "Description":  "Disables Microsoft Telemetry.",
                               "category":  "Essential Tweaks",
                               "panel":  "1",
                               "registry":  [
                                                {
                                                    "Path":  "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\AdvertisingInfo",
                                                    "Name":  "Enabled",
                                                    "Value":  "0",
                                                    "Type":  "DWord",
                                                    "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                },
                                                {
                                                    "Path":  "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Privacy",
                                                    "Name":  "TailoredExperiencesWithDiagnosticDataEnabled",
                                                    "Value":  "0",
                                                    "Type":  "DWord",
                                                    "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                },
                                                {
                                                    "Path":  "HKCU:\\Software\\Microsoft\\Speech_OneCore\\Settings\\OnlineSpeechPrivacy",
                                                    "Name":  "HasAccepted",
                                                    "Value":  "0",
                                                    "Type":  "DWord",
                                                    "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                },
                                                {
                                                    "Path":  "HKCU:\\Software\\Microsoft\\Input\\TIPC",
                                                    "Name":  "Enabled",
                                                    "Value":  "0",
                                                    "Type":  "DWord",
                                                    "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                },
                                                {
                                                    "Path":  "HKCU:\\Software\\Microsoft\\InputPersonalization",
                                                    "Name":  "RestrictImplicitInkCollection",
                                                    "Value":  "1",
                                                    "Type":  "DWord",
                                                    "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                },
                                                {
                                                    "Path":  "HKCU:\\Software\\Microsoft\\InputPersonalization",
                                                    "Name":  "RestrictImplicitTextCollection",
                                                    "Value":  "1",
                                                    "Type":  "DWord",
                                                    "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                },
                                                {
                                                    "Path":  "HKCU:\\Software\\Microsoft\\InputPersonalization\\TrainedDataStore",
                                                    "Name":  "HarvestContacts",
                                                    "Value":  "0",
                                                    "Type":  "DWord",
                                                    "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                },
                                                {
                                                    "Path":  "HKCU:\\Software\\Microsoft\\Personalization\\Settings",
                                                    "Name":  "AcceptedPrivacyPolicy",
                                                    "Value":  "0",
                                                    "Type":  "DWord",
                                                    "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                },
                                                {
                                                    "Path":  "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\DataCollection",
                                                    "Name":  "AllowTelemetry",
                                                    "Value":  "0",
                                                    "Type":  "DWord",
                                                    "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                },
                                                {
                                                    "Path":  "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
                                                    "Name":  "Start_TrackProgs",
                                                    "Value":  "0",
                                                    "Type":  "DWord",
                                                    "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                },
                                                {
                                                    "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\System",
                                                    "Name":  "PublishUserActivities",
                                                    "Value":  "0",
                                                    "Type":  "DWord",
                                                    "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                },
                                                {
                                                    "Path":  "HKCU:\\Software\\Microsoft\\Siuf\\Rules",
                                                    "Name":  "NumberOfSIUFInPeriod",
                                                    "Value":  "0",
                                                    "Type":  "DWord",
                                                    "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                }
                                            ],
                               "InvokeScript":  [
                                                    "\n      # Disable Defender Auto Sample Submission (skipped when Defender is not installed)\n      if (Get-Command Set-MpPreference -ErrorAction SilentlyContinue) { Set-MpPreference -SubmitSamplesConsent 2 }\n\n      # Disable (Connected User Experiences and Telemetry) Service\n      Set-Service -Name diagtrack -StartupType Disabled\n\n      # Disable (Windows Error Reporting Manager) Service; most Windows builds do not have it\n      if (Get-Service -Name wermgr -ErrorAction SilentlyContinue) { Set-Service -Name wermgr -StartupType Disabled }\n\n      # Disable PowerShell 7 telemetry\n      [Environment]::SetEnvironmentVariable(\u0027POWERSHELL_TELEMETRY_OPTOUT\u0027, \u00271\u0027, \u0027Machine\u0027)\n\n      Remove-ItemProperty -Path \"HKCU:\\Software\\Microsoft\\Siuf\\Rules\" -Name PeriodInNanoSeconds -ErrorAction SilentlyContinue\n      "
                                                ],
                               "UndoScript":  [
                                                  "\n      # Enable Defender Auto Sample Submission (skipped when Defender is not installed)\n      if (Get-Command Set-MpPreference -ErrorAction SilentlyContinue) { Set-MpPreference -SubmitSamplesConsent 1 }\n\n      # Enable (Connected User Experiences and Telemetry) Service\n      Set-Service -Name diagtrack -StartupType Automatic\n\n      # Enable (Windows Error Reporting Manager) Service; most Windows builds do not have it\n      if (Get-Service -Name wermgr -ErrorAction SilentlyContinue) { Set-Service -Name wermgr -StartupType Automatic }\n\n      # Enable PowerShell 7 telemetry\n      [Environment]::SetEnvironmentVariable(\u0027POWERSHELL_TELEMETRY_OPTOUT\u0027, \u0027\u0027, \u0027Machine\u0027)\n      "
                                              ],
                               "link":  "https://winutil.christitus.com/code-reference/tweaks/essential-tweaks/telemetry"
                           },
    "WPFTweaksDeliveryOptimization":  {
                                          "Content":  "Delivery Optimization - Disable",
                                          "Description":  "Stops Windows from using your bandwidth to upload updates to other PCs on the internet or local network.",
                                          "category":  "Essential Tweaks",
                                          "panel":  "1",
                                          "registry":  [
                                                           {
                                                               "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\DeliveryOptimization",
                                                               "Name":  "DODownloadMode",
                                                               "Value":  "0",
                                                               "Type":  "DWord",
                                                               "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                           }
                                                       ],
                                          "link":  "https://winutil.christitus.com/code-reference/tweaks/essential-tweaks/deliveryoptimization"
                                      },
    "WPFTweaksRemoveEdge":  {
                                "Content":  "Microsoft Edge - Remove",
                                "Description":  "Uninstalls Microsoft Edge by creating dummy MicrosoftEdge.exe file in the legacy Edge folder. This tricks Windows into unlocking the official Edge uninstaller allowing for a system-level removal.",
                                "category":  "z__Advanced Tweaks - CAUTION",
                                "panel":  "1",
                                "InvokeScript":  [
                                                     "\n      $Path = Resolve-Path -Path \"$Env:ProgramFiles (x86)\\Microsoft\\Edge\\Application\\*\\Installer\\setup.exe\" | Select-Object -Last 1\n\n      if (Test-Path $Path) {\n          New-Item -Path \"$Env:SystemRoot\\SystemApps\\Microsoft.MicrosoftEdge_8wekyb3d8bbwe\\MicrosoftEdge.exe\" -Force\n          Start-Process -FilePath $Path -ArgumentList \"--uninstall --system-level --force-uninstall --delete-profile\" -Wait\n          Write-Host \"Microsoft Edge was removed\"\n      } else {\n          Write-Host \"Microsoft Edge is not installed\"\n      }\n      "
                                                 ],
                                "UndoScript":  [
                                                   "\n      Write-Host \"Installing Microsoft Edge...\"\n      winget install Microsoft.Edge --source winget\n      "
                                               ],
                                "link":  "https://winutil.christitus.com/code-reference/tweaks/z--advanced-tweaks---caution/removeedge"
                            },
    "WPFTweaksDisableBitLocker":  {
                                      "Content":  "BitLocker - Disable",
                                      "Description":  "Disables BitLocker.",
                                      "category":  "Essential Tweaks",
                                      "panel":  "1",
                                      "InvokeScript":  [
                                                           "Disable-BitLocker -MountPoint $Env:SystemDrive"
                                                       ],
                                      "UndoScript":  [
                                                         "Enable-BitLocker -MountPoint $Env:SystemDrive"
                                                     ],
                                      "link":  "https://winutil.christitus.com/code-reference/tweaks/essential-tweaks/disablebitlocker"
                                  },
    "WPFTweaksUTC":  {
                         "Content":  "Date \u0026 Time - Set Time to UTC",
                         "Description":  "Essential for computers that are dual booting. Fixes the time sync with Linux systems.",
                         "category":  "z__Advanced Tweaks - CAUTION",
                         "panel":  "1",
                         "registry":  [
                                          {
                                              "Path":  "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\TimeZoneInformation",
                                              "Name":  "RealTimeIsUniversal",
                                              "Value":  "1",
                                              "Type":  "QWord",
                                              "OriginalValue":  "0"
                                          }
                                      ],
                         "link":  "https://winutil.christitus.com/code-reference/tweaks/z--advanced-tweaks---caution/utc"
                     },
    "WPFTweaksRemoveOneDrive":  {
                                    "Content":  "Microsoft OneDrive - Remove",
                                    "Description":  "Denies permission to remove OneDrive user files, then uses its own uninstaller to remove it and restores the original permission afterward.",
                                    "category":  "z__Advanced Tweaks - CAUTION",
                                    "panel":  "1",
                                    "InvokeScript":  [
                                                         "\n      # Deny permission to remove OneDrive folder\n      icacls $Env:OneDrive /deny \"*S-1-5-32-544:(D,DC)\"\n\n      Write-Host \"Uninstalling OneDrive...\"\n      Start-Process -FilePath (Join-Path $Env:SystemRoot \"System32\\OneDriveSetup.exe\") -ArgumentList \u0027/uninstall\u0027 -Wait\n\n      # Some of OneDrive files use explorer, and OneDrive uses FileCoAuth\n      Write-Host \"Removing leftover OneDrive Files...\"\n\n      Stop-Process -Name FileCoAuth,Explorer\n\n      Remove-Item \"$Env:LocalAppData\\Microsoft\\OneDrive\" -Recurse -Force\n      Remove-Item \"$Env:ProgramData\\Microsoft OneDrive\" -Recurse -Force\n\n      # Grant back permission to access OneDrive folder\n      icacls $Env:OneDrive /grant \"*S-1-5-32-544:(D,DC)\"\n\n      if (-not (Get-ChildItem -Path $Env:OneDrive)) {\n          Remove-Item -Path $Env:OneDrive -Recurse\n          [Environment]::SetEnvironmentVariable(\u0027OneDrive\u0027, $null, \u0027User\u0027)\n      }\n\n      # Disable OneSyncSvc\n      Set-Service -Name OneSyncSvc -StartupType Disabled\n      "
                                                     ],
                                    "UndoScript":  [
                                                       "\n      Write-Host \"Installing OneDrive\"\n      winget install Microsoft.Onedrive --source winget\n\n      # Enabled OneSyncSvc\n      Set-Service -Name OneSyncSvc -StartupType Automatic\n      "
                                                   ],
                                    "link":  "https://winutil.christitus.com/code-reference/tweaks/z--advanced-tweaks---caution/removeonedrive"
                                },
    "WPFTweaksRemoveHomeAndGallery":  {
                                          "Content":  "File Explorer Home and Gallery - Disable",
                                          "Description":  "Removes the Home and Gallery from Explorer and sets This PC as default.",
                                          "category":  "z__Advanced Tweaks - CAUTION",
                                          "panel":  "1",
                                          "registry":  [
                                                           {
                                                               "Path":  "HKCU:\\Software\\Classes\\CLSID\\{f874310e-b6b7-47dc-bc84-b9e6b38f5903}",
                                                               "Name":  "System.IsPinnedToNameSpaceTree",
                                                               "Value":  "0",
                                                               "Type":  "DWord",
                                                               "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                           },
                                                           {
                                                               "Path":  "HKCU:\\Software\\Classes\\CLSID\\{e88865ea-0e1c-4e20-9aa6-edcd0212c87c}",
                                                               "Name":  "System.IsPinnedToNameSpaceTree",
                                                               "Value":  "0",
                                                               "Type":  "DWord",
                                                               "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                           },
                                                           {
                                                               "Path":  "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
                                                               "Name":  "LaunchTo",
                                                               "Value":  "1",
                                                               "Type":  "DWord",
                                                               "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                           }
                                                       ],
                                          "link":  "https://winutil.christitus.com/code-reference/tweaks/z--advanced-tweaks---caution/removehomeandgallery"
                                      },
    "WPFTweaksDisplay":  {
                             "Content":  "Visual Effects - Set to Best Performance",
                             "Description":  "Sets the system preferences to performance. You can do this manually with sysdm.cpl as well.",
                             "category":  "z__Advanced Tweaks - CAUTION",
                             "panel":  "1",
                             "registry":  [
                                              {
                                                  "Path":  "HKCU:\\Control Panel\\Desktop",
                                                  "Name":  "DragFullWindows",
                                                  "Value":  "0",
                                                  "Type":  "String",
                                                  "OriginalValue":  "1"
                                              },
                                              {
                                                  "Path":  "HKCU:\\Control Panel\\Desktop",
                                                  "Name":  "MenuShowDelay",
                                                  "Value":  "200",
                                                  "Type":  "String",
                                                  "OriginalValue":  "400"
                                              },
                                              {
                                                  "Path":  "HKCU:\\Control Panel\\Desktop\\WindowMetrics",
                                                  "Name":  "MinAnimate",
                                                  "Value":  "0",
                                                  "Type":  "String",
                                                  "OriginalValue":  "1"
                                              },
                                              {
                                                  "Path":  "HKCU:\\Control Panel\\Keyboard",
                                                  "Name":  "KeyboardDelay",
                                                  "Value":  "0",
                                                  "Type":  "DWord",
                                                  "OriginalValue":  "1"
                                              },
                                              {
                                                  "Path":  "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
                                                  "Name":  "ListviewAlphaSelect",
                                                  "Value":  "0",
                                                  "Type":  "DWord",
                                                  "OriginalValue":  "1"
                                              },
                                              {
                                                  "Path":  "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
                                                  "Name":  "ListviewShadow",
                                                  "Value":  "0",
                                                  "Type":  "DWord",
                                                  "OriginalValue":  "1"
                                              },
                                              {
                                                  "Path":  "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
                                                  "Name":  "TaskbarAnimations",
                                                  "Value":  "0",
                                                  "Type":  "DWord",
                                                  "OriginalValue":  "1"
                                              },
                                              {
                                                  "Path":  "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\VisualEffects",
                                                  "Name":  "VisualFXSetting",
                                                  "Value":  "3",
                                                  "Type":  "DWord",
                                                  "OriginalValue":  "1"
                                              },
                                              {
                                                  "Path":  "HKCU:\\Software\\Microsoft\\Windows\\DWM",
                                                  "Name":  "EnableAeroPeek",
                                                  "Value":  "0",
                                                  "Type":  "DWord",
                                                  "OriginalValue":  "1"
                                              },
                                              {
                                                  "Path":  "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
                                                  "Name":  "TaskbarMn",
                                                  "Value":  "0",
                                                  "Type":  "DWord",
                                                  "OriginalValue":  "1"
                                              },
                                              {
                                                  "Path":  "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
                                                  "Name":  "ShowTaskViewButton",
                                                  "Value":  "0",
                                                  "Type":  "DWord",
                                                  "OriginalValue":  "1"
                                              },
                                              {
                                                  "Path":  "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Search",
                                                  "Name":  "SearchboxTaskbarMode",
                                                  "Value":  "0",
                                                  "Type":  "DWord",
                                                  "OriginalValue":  "1"
                                              }
                                          ],
                             "InvokeScript":  [
                                                  "Set-ItemProperty -Path \"HKCU:\\Control Panel\\Desktop\" -Name \"UserPreferencesMask\" -Type Binary -Value ([byte[]](144,18,3,128,16,0,0,0))"
                                              ],
                             "UndoScript":  [
                                                "Remove-ItemProperty -Path \"HKCU:\\Control Panel\\Desktop\" -Name \"UserPreferencesMask\""
                                            ],
                             "link":  "https://winutil.christitus.com/code-reference/tweaks/z--advanced-tweaks---caution/display"
                         },
    "WPFTweaksReservedStorage":  {
                                     "Content":  "Disable Reserved Storage",
                                     "Description":  "Disables Windows Reserved Storage (7-10 GB held for updates/temp files). Recommended only on small drives. Re-enable before major Windows feature updates to avoid installation failures.",
                                     "category":  "z__Advanced Tweaks - CAUTION",
                                     "panel":  "1",
                                     "InvokeScript":  [
                                                          "DISM /Online /Set-ReservedStorageState /State:Disabled"
                                                      ],
                                     "UndoScript":  [
                                                        "DISM /Online /Set-ReservedStorageState /State:Enabled"
                                                    ],
                                     "link":  "https://winutil.christitus.com/code-reference/tweaks/z--advanced-tweaks---caution/reservedstorage"
                                 },
    "WPFTweaksRestorePoint":  {
                                  "Content":  "Restore Point - Create",
                                  "Description":  "Creates a restore point at runtime in case a revert is needed from WinUtil modifications.",
                                  "category":  "Essential Tweaks",
                                  "panel":  "1",
                                  "Checked":  "False",
                                  "registry":  [
                                                   {
                                                       "Path":  "HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\SystemRestore",
                                                       "Name":  "SystemRestorePointCreationFrequency",
                                                       "Value":  "0",
                                                       "Type":  "DWord",
                                                       "OriginalValue":  "1440"
                                                   }
                                               ],
                                  "InvokeScript":  [
                                                       "\n      if (-not (Get-ComputerRestorePoint)) {\n          Enable-ComputerRestore -Drive $Env:SystemDrive\n      }\n\n      Checkpoint-Computer -Description \"System Restore Point created by WinUtil\" -RestorePointType MODIFY_SETTINGS\n      Write-Host \"System Restore Point Created Successfully\" -ForegroundColor Green\n      "
                                                   ],
                                  "link":  "https://winutil.christitus.com/code-reference/tweaks/essential-tweaks/restorepoint"
                              },
    "WPFTweaksEndTaskOnTaskbar":  {
                                      "Content":  "End Task With Right Click - Enable",
                                      "Description":  "Enables option to end task when right-clicking a program in the taskbar.",
                                      "category":  "Essential Tweaks",
                                      "panel":  "1",
                                      "registry":  [
                                                       {
                                                           "Path":  "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced\\TaskbarDeveloperSettings",
                                                           "Name":  "TaskbarEndTask",
                                                           "Value":  "1",
                                                           "Type":  "DWord",
                                                           "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                       }
                                                   ],
                                      "link":  "https://winutil.christitus.com/code-reference/tweaks/essential-tweaks/endtaskontaskbar"
                                  },
    "WPFTweaksStorage":  {
                             "Content":  "Storage Sense - Disable",
                             "Description":  "Storage Sense deletes temp files automatically.",
                             "category":  "z__Advanced Tweaks - CAUTION",
                             "panel":  "1",
                             "registry":  [
                                              {
                                                  "Path":  "HKCU:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\StorageSense\\Parameters\\StoragePolicy",
                                                  "Name":  "01",
                                                  "Value":  "0",
                                                  "Type":  "DWord",
                                                  "OriginalValue":  "1"
                                              }
                                          ],
                             "link":  "https://winutil.christitus.com/code-reference/tweaks/z--advanced-tweaks---caution/storage"
                         },
    "WPFTweaksWindowsAI":  {
                               "Content":  "Windows AI - Disable And Remove",
                               "Description":  "Removes and disables all AI features/packages",
                               "category":  "z__Advanced Tweaks - CAUTION",
                               "panel":  "1",
                               "registry":  [
                                                {
                                                    "Path":  "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\Explorer",
                                                    "Name":  "SettingsPageVisibility",
                                                    "Value":  "hide:aicomponents",
                                                    "Type":  "String",
                                                    "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                },
                                                {
                                                    "Path":  "HKLM:\\SOFTWARE\\Policies\\WindowsNotepad",
                                                    "Name":  "DisableAIFeatures",
                                                    "Value":  "1",
                                                    "Type":  "DWord",
                                                    "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                }
                                            ],
                               "InvokeScript":  [
                                                    "\n      $Appx = (Get-AppxPackage MicrosoftWindows.Client.CoreAI).PackageFullName\n      $Sid = (Get-LocalUser $Env:UserName).Sid.Value\n\n      New-Item \"HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Appx\\AppxAllUserStore\\EndOfLife\\$Sid\\$Appx\" -Force\n\n      Get-AppxPackage -AllUsers \"*Copilot*\" | Remove-AppxPackage -AllUsers\n      winget uninstall -e --name \"Copilot\" --silent --force --accept-source-agreements 2\u003e$null\n      Get-AppxPackage -AllUsers Microsoft.MicrosoftOfficeHub | Remove-AppxPackage -AllUsers\n\n      if ($Appx) {\n          Remove-AppxPackage $Appx\n      }\n\n      Set-Service -Name WSAIFabricSvc -StartupType Disabled\n      Disable-WindowsOptionalFeature -FeatureName Recall -Online -NoRestart\n\n      Write-Host \"Windows AI Disabled\"\n      "
                                                ],
                               "link":  "https://winutil.christitus.com/code-reference/tweaks/z--advanced-tweaks---caution/windowsai"
                           },
    "WPFTweaksWPBT":  {
                          "Content":  "Windows Platform Binary Table (WPBT) - Disable",
                          "Description":  "If enabled, WPBT allows your computer vendor to execute programs at boot time, such as anti-theft software, software drivers, as well as force install software without user consent. Poses potential security risk.",
                          "category":  "Essential Tweaks",
                          "panel":  "1",
                          "registry":  [
                                           {
                                               "Path":  "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Session Manager",
                                               "Name":  "DisableWpbtExecution",
                                               "Value":  "1",
                                               "Type":  "DWord",
                                               "OriginalValue":  "\u003cRemoveEntry\u003e"
                                           }
                                       ],
                          "link":  "https://winutil.christitus.com/code-reference/tweaks/essential-tweaks/wpbt"
                      },
    "WPFTweaksPreventDeviceMetadataFromNetwork":  {
                                                      "Content":  "Prevent Device Companion Apps",
                                                      "Description":  "Prevents additional software from being installed when plugging in devices (e.g. Ads when plugging in a monitor). Poses potential security risk.",
                                                      "category":  "Essential Tweaks",
                                                      "panel":  "1",
                                                      "registry":  [
                                                                       {
                                                                           "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\Device Metadata",
                                                                           "Name":  "PreventDeviceMetadataFromNetwork",
                                                                           "Value":  "1",
                                                                           "Type":  "DWord",
                                                                           "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                                       }
                                                                   ],
                                                      "link":  "https://winutil.christitus.com/code-reference/tweaks/essential-tweaks/preventdevicemetadatafromnetwork"
                                                  },
    "WPFTweaksRazerBlock":  {
                                "Content":  "Razer Software Auto-Install - Disable",
                                "Description":  "Blocks ALL Razer Software installations. The hardware works fine without any software.",
                                "category":  "z__Advanced Tweaks - CAUTION",
                                "panel":  "1",
                                "registry":  [
                                                 {
                                                     "Path":  "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\DriverSearching",
                                                     "Name":  "SearchOrderConfig",
                                                     "Value":  "0",
                                                     "Type":  "DWord",
                                                     "OriginalValue":  "1"
                                                 },
                                                 {
                                                     "Path":  "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Device Installer",
                                                     "Name":  "DisableCoInstallers",
                                                     "Value":  "1",
                                                     "Type":  "DWord",
                                                     "OriginalValue":  "0"
                                                 }
                                             ],
                                "InvokeScript":  [
                                                     "\n      $RazerPath = \"$Env:SystemRoot\\Installer\\Razer\"\n\n      if (Test-Path $RazerPath) {\n        Remove-Item $RazerPath\\* -Recurse -Force\n      } else {\n        New-Item -Path $RazerPath -ItemType Directory\n      }\n\n      icacls $RazerPath /deny \"*S-1-1-0:(W)\"\n      "
                                                 ],
                                "UndoScript":  [
                                                   "\n      icacls \"$Env:SystemRoot\\Installer\\Razer\" /remove:d *S-1-1-0\n      "
                                               ],
                                "link":  "https://winutil.christitus.com/code-reference/tweaks/z--advanced-tweaks---caution/razerblock"
                            },
    "WPFTweaksLogiBlock":  {
                               "Content":  "Logitech Download Assistant Auto-Install - Disable",
                               "Description":  "Blocks the Logi Download Assistant that Windows Update keeps reinstalling with Logitech device drivers. Logitech hardware keeps working without it.",
                               "category":  "z__Advanced Tweaks - CAUTION",
                               "panel":  "1",
                               "InvokeScript":  [
                                                    "\n      Stop-Process -Name \"logi_download_assistant\" -Force -ErrorAction SilentlyContinue\n\n      $ProgramFiles64 = if ($Env:ProgramW6432) { $Env:ProgramW6432 } else { $Env:ProgramFiles }\n      $LogiPath = \"$ProgramFiles64\\LogiDownloadAssistant\"\n\n      if (Test-Path $LogiPath) {\n        Remove-Item $LogiPath\\* -Recurse -Force\n      } else {\n        New-Item -Path $LogiPath -ItemType Directory\n      }\n\n      icacls $LogiPath /deny \"*S-1-1-0:(W)\"\n      if ($LASTEXITCODE -ne 0) { throw \"icacls failed to deny write access on $LogiPath (exit code $LASTEXITCODE)\" }\n      "
                                                ],
                               "UndoScript":  [
                                                  "\n      $ProgramFiles64 = if ($Env:ProgramW6432) { $Env:ProgramW6432 } else { $Env:ProgramFiles }\n      $LogiPath = \"$ProgramFiles64\\LogiDownloadAssistant\"\n\n      if (Test-Path $LogiPath) {\n        icacls $LogiPath /remove:d \"*S-1-1-0\"\n        if ($LASTEXITCODE -ne 0) { throw \"icacls failed to remove the write-deny rule on $LogiPath (exit code $LASTEXITCODE)\" }\n      }\n      "
                                              ],
                               "link":  "https://winutil.christitus.com/code-reference/tweaks/z--advanced-tweaks---caution/logiblock"
                           },
    "WPFTweaksDisableNotifications":  {
                                          "Content":  "System Tray Notifications \u0026 Calendar - Disable",
                                          "Description":  "Disables all Notifications INCLUDING Calendar.",
                                          "category":  "z__Advanced Tweaks - CAUTION",
                                          "panel":  "1",
                                          "registry":  [
                                                           {
                                                               "Path":  "HKCU:\\Software\\Policies\\Microsoft\\Windows\\Explorer",
                                                               "Name":  "DisableNotificationCenter",
                                                               "Value":  "1",
                                                               "Type":  "DWord",
                                                               "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                           },
                                                           {
                                                               "Path":  "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\PushNotifications",
                                                               "Name":  "ToastEnabled",
                                                               "Value":  "0",
                                                               "Type":  "DWord",
                                                               "OriginalValue":  "1"
                                                           }
                                                       ],
                                          "link":  "https://winutil.christitus.com/code-reference/tweaks/z--advanced-tweaks---caution/disablenotifications"
                                      },
    "WPFTweaksBlockAdobeNet":  {
                                   "Content":  "Adobe URL Block List - Enable",
                                   "Description":  "Reduces user interruptions by selectively blocking connections to Adobe\u0027s activation and telemetry servers. Credit: Ruddernation-Designs",
                                   "category":  "z__Advanced Tweaks - CAUTION",
                                   "panel":  "1",
                                   "InvokeScript":  [
                                                        "\n      $hostsUrl = Invoke-RestMethod -Uri https://github.com/Ruddernation-Designs/Adobe-URL-Block-List/raw/refs/heads/master/hosts\n      Add-Content -Path \"$Env:SystemRoot\\System32\\drivers\\etc\\hosts\" -Value $hostsUrl\n\n      ipconfig /flushdns\n      Write-Host \u0027Added Adobe url block list from host file\u0027\n      "
                                                    ],
                                   "UndoScript":  [
                                                      "\n      Set-Content \"$Env:SystemRoot\\System32\\drivers\\etc\\hosts\" (\n          (Get-Content \"$Env:SystemRoot\\System32\\drivers\\etc\\hosts\") -join \"`n\" -replace \u0027(?s)#New Ver.*\u0027, \u0027\u0027\n      )\n\n      ipconfig /flushdns\n      Write-Host \u0027Removed Adobe url block list from host file\u0027\n      "
                                                  ],
                                   "link":  "https://winutil.christitus.com/code-reference/tweaks/z--advanced-tweaks---caution/blockadobenet"
                               },
    "WPFTweaksRightClickMenu":  {
                                    "Content":  "Right-Click Menu Previous Layout - Enable",
                                    "Description":  "Restores the classic context menu when right-clicking in File Explorer, replacing the simplified Windows 11 version.",
                                    "category":  "z__Advanced Tweaks - CAUTION",
                                    "panel":  "1",
                                    "InvokeScript":  [
                                                         "\n      New-Item -Path \"HKCU:\\Software\\Classes\\CLSID\\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\" -Name InprocServer32 -Value \"\" -Force\n      Stop-Process -Name explorer\n      "
                                                     ],
                                    "UndoScript":  [
                                                       "Remove-Item -Path \"HKCU:\\Software\\Classes\\CLSID\\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\" -Recurse"
                                                   ],
                                    "link":  "https://winutil.christitus.com/code-reference/tweaks/z--advanced-tweaks---caution/rightclickmenu"
                                },
    "WPFTweaksDiskCleanup":  {
                                 "Content":  "Disk Cleanup - Run",
                                 "Description":  "Runs Disk Cleanup on Drive C: and removes old Windows Updates.",
                                 "category":  "Essential Tweaks",
                                 "panel":  "1",
                                 "InvokeScript":  [
                                                      "\n      cleanmgr.exe /d C: /VERYLOWDISK\n      Dism.exe /online /Cleanup-Image /StartComponentCleanup /ResetBase\n      "
                                                  ],
                                 "link":  "https://winutil.christitus.com/code-reference/tweaks/essential-tweaks/diskcleanup"
                             },
    "WPFTweaksDeleteTempFiles":  {
                                     "Content":  "Temporary Files - Remove",
                                     "Description":  "Erases TEMP Folders.",
                                     "category":  "Essential Tweaks",
                                     "panel":  "1",
                                     "InvokeScript":  [
                                                          "\n      # A temp folder always holds files something has open, including this run\u0027s own, and\n      # the job layer counts a logged error as a failed step\n      Remove-Item -Path \"$Env:Temp\\*\" -Recurse -Force -ErrorAction SilentlyContinue\n      Remove-Item -Path \"$Env:SystemRoot\\Temp\\*\" -Recurse -Force -ErrorAction SilentlyContinue\n      "
                                                      ],
                                     "link":  "https://winutil.christitus.com/code-reference/tweaks/essential-tweaks/deletetempfiles"
                                 },
    "WPFTweaksIPv46":  {
                           "Content":  "IPv6 - Set IPv4 as Preferred",
                           "Description":  "Setting the IPv4 preference can have latency and security benefits on private networks where IPv6 is not configured.",
                           "category":  "z__Advanced Tweaks - CAUTION",
                           "panel":  "1",
                           "registry":  [
                                            {
                                                "Path":  "HKLM:\\SYSTEM\\CurrentControlSet\\Services\\Tcpip6\\Parameters",
                                                "Name":  "DisabledComponents",
                                                "Value":  "32",
                                                "Type":  "DWord",
                                                "OriginalValue":  "0"
                                            }
                                        ],
                           "link":  "https://winutil.christitus.com/code-reference/tweaks/z--advanced-tweaks---caution/ipv46"
                       },
    "WPFTweaksTeredo":  {
                            "Content":  "Teredo - Disable",
                            "Description":  "Teredo network tunneling is an IPv6 feature that can cause additional latency, but may cause problems with some games.",
                            "category":  "z__Advanced Tweaks - CAUTION",
                            "panel":  "1",
                            "registry":  [
                                             {
                                                 "Path":  "HKLM:\\SYSTEM\\CurrentControlSet\\Services\\Tcpip6\\Parameters",
                                                 "Name":  "DisabledComponents",
                                                 "Value":  "1",
                                                 "Type":  "DWord",
                                                 "OriginalValue":  "0"
                                             }
                                         ],
                            "InvokeScript":  [
                                                 "netsh interface teredo set state disabled"
                                             ],
                            "UndoScript":  [
                                               "netsh interface teredo set state default"
                                           ],
                            "link":  "https://winutil.christitus.com/code-reference/tweaks/z--advanced-tweaks---caution/teredo"
                        },
    "WPFTweaksDisableIPv6":  {
                                 "Content":  "IPv6 - Disable",
                                 "Description":  "Disables IPv6.",
                                 "category":  "z__Advanced Tweaks - CAUTION",
                                 "panel":  "1",
                                 "registry":  [
                                                  {
                                                      "Path":  "HKLM:\\SYSTEM\\CurrentControlSet\\Services\\Tcpip6\\Parameters",
                                                      "Name":  "DisabledComponents",
                                                      "Value":  "255",
                                                      "Type":  "DWord",
                                                      "OriginalValue":  "0"
                                                  }
                                              ],
                                 "InvokeScript":  [
                                                      "Disable-NetAdapterBinding -Name * -ComponentID ms_tcpip6"
                                                  ],
                                 "UndoScript":  [
                                                    "Enable-NetAdapterBinding -Name * -ComponentID ms_tcpip6"
                                                ],
                                 "link":  "https://winutil.christitus.com/code-reference/tweaks/z--advanced-tweaks---caution/disableipv6"
                             },
    "WPFTweaksDisableBGapps":  {
                                   "Content":  "Background Apps - Disable",
                                   "Description":  "Disables all Microsoft Store apps from running in the background, which has to be done individually since Windows 11.",
                                   "category":  "z__Advanced Tweaks - CAUTION",
                                   "panel":  "1",
                                   "registry":  [
                                                    {
                                                        "Path":  "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\BackgroundAccessApplications",
                                                        "Name":  "GlobalUserDisabled",
                                                        "Value":  "1",
                                                        "Type":  "DWord",
                                                        "OriginalValue":  "0"
                                                    }
                                                ],
                                   "link":  "https://winutil.christitus.com/code-reference/tweaks/z--advanced-tweaks---caution/disablebgapps"
                               },
    "WPFTweaksDeBloat":  {
                             "Content":  "Remove ALL MS Store Apps - NOT RECOMMENDED",
                             "Description":  "High impact: removes a legacy WinUtil list of Microsoft Store apps for all users and deprovisions them for new accounts. This includes Minecraft Bedrock, Gaming Services, media apps, communications apps and some third-party Store apps when present. It does not literally remove every Store app: Microsoft Store and essential frameworks are left alone. No automatic Undo is available; removed apps and games must be reinstalled separately, and some app data may be lost.",
                             "category":  "z__Advanced Tweaks - CAUTION",
                             "panel":  "1",
                             "Checked":  "False",
                             "appx":  [
                                          "Microsoft.Microsoft3DViewer",
                                          "Microsoft.AppConnector",
                                          "Microsoft.BingFinance",
                                          "Microsoft.BingNews",
                                          "Microsoft.BingSports",
                                          "Microsoft.BingTranslator",
                                          "Microsoft.BingWeather",
                                          "Microsoft.BingFoodAndDrink",
                                          "Microsoft.BingHealthAndFitness",
                                          "Microsoft.BingTravel",
                                          "Microsoft.MinecraftUWP",
                                          "Microsoft.GamingServices",
                                          "Microsoft.GetHelp",
                                          "Microsoft.Getstarted",
                                          "Microsoft.Messaging",
                                          "Microsoft.MicrosoftSolitaireCollection",
                                          "Microsoft.NetworkSpeedTest",
                                          "Microsoft.News",
                                          "Microsoft.Office.Lens",
                                          "Microsoft.Office.Sway",
                                          "Microsoft.Office.OneNote",
                                          "Microsoft.OneConnect",
                                          "Microsoft.People",
                                          "Microsoft.Print3D",
                                          "Microsoft.SkypeApp",
                                          "Microsoft.Wallet",
                                          "Microsoft.Whiteboard",
                                          "Microsoft.WindowsAlarms",
                                          "microsoft.windowscommunicationsapps",
                                          "Microsoft.WindowsFeedbackHub",
                                          "Microsoft.WindowsMaps",
                                          "Microsoft.WindowsSoundRecorder",
                                          "Microsoft.ConnectivityStore",
                                          "Microsoft.ScreenSketch",
                                          "Microsoft.MixedReality.Portal",
                                          "Microsoft.ZuneMusic",
                                          "Microsoft.ZuneVideo",
                                          "Microsoft.MicrosoftOfficeHub",
                                          "*EclipseManager*",
                                          "*ActiproSoftwareLLC*",
                                          "*AdobeSystemsIncorporated.AdobePhotoshopExpress*",
                                          "*Duolingo-LearnLanguagesforFree*",
                                          "*PandoraMediaInc*",
                                          "*CandyCrush*",
                                          "*BubbleWitch3Saga*",
                                          "*Wunderlist*",
                                          "*Flipboard*",
                                          "*Twitter*",
                                          "*Facebook*",
                                          "*Royal Revolt*",
                                          "*Sway*",
                                          "*Speed Test*",
                                          "*Dolby*",
                                          "*Viber*",
                                          "*ACGMediaPlayer*",
                                          "*Netflix*",
                                          "*OneCalendar*",
                                          "*LinkedInforWindows*",
                                          "*HiddenCityMysteryofShadows*",
                                          "*Hulu*",
                                          "*HiddenCity*",
                                          "*AdobePhotoshopExpress*",
                                          "*HotspotShieldFreeVPN*"
                                      ]
                         },
    "WPFTweaksDisableExplorerAutoDiscovery":  {
                                                  "Content":  "File Explorer Automatic Folder Discovery - Disable",
                                                  "Description":  "Windows Explorer automatically tries to guess the type of the folder based on its contents, slowing down the browsing experience. WARNING! Will disable File Explorer grouping.",
                                                  "category":  "Essential Tweaks",
                                                  "panel":  "1",
                                                  "InvokeScript":  [
                                                                       "\n      # Previously detected folders\n      $bags = \"HKCU:\\Software\\Classes\\Local Settings\\Software\\Microsoft\\Windows\\Shell\\Bags\"\n\n      # Folder types lookup table\n      $bagMRU = \"HKCU:\\Software\\Classes\\Local Settings\\Software\\Microsoft\\Windows\\Shell\\BagMRU\"\n\n      # Flush Explorer view database\n      Remove-Item -Path $bags -Recurse -Force\n      Write-Host \"Removed $bags\"\n\n      Remove-Item -Path $bagMRU -Recurse -Force\n      Write-Host \"Removed $bagMRU\"\n\n      # Every folder\n      $allFolders = \"HKCU:\\Software\\Classes\\Local Settings\\Software\\Microsoft\\Windows\\Shell\\Bags\\AllFolders\\Shell\"\n\n      if (!(Test-Path $allFolders)) {\n        New-Item -Path $allFolders -Force\n        Write-Host \"Created $allFolders\"\n      }\n\n      # Generic view\n      New-ItemProperty -Path $allFolders -Name \"FolderType\" -Value \"NotSpecified\" -PropertyType String -Force\n      Write-Host \"Set FolderType to NotSpecified\"\n\n      Write-Host Please sign out and back in, or restart your computer to apply the changes!\n      "
                                                                   ],
                                                  "UndoScript":  [
                                                                     "\n      # Previously detected folders\n      $bags = \"HKCU:\\Software\\Classes\\Local Settings\\Software\\Microsoft\\Windows\\Shell\\Bags\"\n\n      # Folder types lookup table\n      $bagMRU = \"HKCU:\\Software\\Classes\\Local Settings\\Software\\Microsoft\\Windows\\Shell\\BagMRU\"\n\n      # Flush Explorer view database\n      Remove-Item -Path $bags -Recurse -Force\n      Write-Host \"Removed $bags\"\n\n      Remove-Item -Path $bagMRU -Recurse -Force\n      Write-Host \"Removed $bagMRU\"\n\n      Write-Host Please sign out and back in, or restart your computer to apply the changes!\n      "
                                                                 ],
                                                  "link":  "https://winutil.christitus.com/code-reference/tweaks/essential-tweaks/disableexplorerautodiscovery"
                                              },
    "WPFToggleDetailedBSoD":  {
                                  "Content":  "BSoD Verbose Mode",
                                  "Description":  "Gives more information when you blue screen.",
                                  "category":  "Customize Preferences",
                                  "panel":  "2",
                                  "Type":  "Toggle",
                                  "registry":  [
                                                   {
                                                       "Path":  "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\CrashControl",
                                                       "Name":  "DisplayParameters",
                                                       "Value":  "1",
                                                       "Type":  "DWord",
                                                       "OriginalValue":  "0",
                                                       "DefaultState":  "false"
                                                   },
                                                   {
                                                       "Path":  "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\CrashControl",
                                                       "Name":  "DisableEmoticon",
                                                       "Value":  "1",
                                                       "Type":  "DWord",
                                                       "OriginalValue":  "0",
                                                       "DefaultState":  "false"
                                                   }
                                               ],
                                  "link":  "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/detailedbsod"
                              },
    "WPFToggleBatteryPercentage":  {
                                       "Content":  "System Tray Battery Percentage",
                                       "Description":  "Shows numeric battery percentage next to the battery icon in the system tray.",
                                       "category":  "Customize Preferences",
                                       "panel":  "2",
                                       "Type":  "Toggle",
                                       "registry":  [
                                                        {
                                                            "Path":  "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
                                                            "Name":  "IsBatteryPercentageEnabled",
                                                            "Value":  "1",
                                                            "Type":  "DWord",
                                                            "OriginalValue":  "\u003cRemoveEntry\u003e",
                                                            "DefaultState":  "false"
                                                        }
                                                    ],
                                       "link":  "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/batterypercentage"
                                   },
    "WPFToggleDarkMode":  {
                              "Content":  "Dark Theme for Windows",
                              "Description":  "Dark Mode for the system and applications.",
                              "category":  "Customize Preferences",
                              "panel":  "2",
                              "Type":  "Toggle",
                              "registry":  [
                                               {
                                                   "Path":  "HKCU:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
                                                   "Name":  "AppsUseLightTheme",
                                                   "Value":  "0",
                                                   "Type":  "DWord",
                                                   "OriginalValue":  "1",
                                                   "DefaultState":  "false"
                                               },
                                               {
                                                   "Path":  "HKCU:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
                                                   "Name":  "SystemUsesLightTheme",
                                                   "Value":  "0",
                                                   "Type":  "DWord",
                                                   "OriginalValue":  "1",
                                                   "DefaultState":  "false"
                                               }
                                           ],
                              "InvokeScript":  [
                                                   "\n      Invoke-WinUtilExplorerUpdate\n      if ($sync.ThemeButton.Content -eq [char]0xF08C) {\n        Invoke-WinutilThemeChange -theme \"Auto\"\n      }\n      "
                                               ],
                              "UndoScript":  [
                                                 "\n      Invoke-WinUtilExplorerUpdate\n      if ($sync.ThemeButton.Content -eq [char]0xF08C) {\n        Invoke-WinutilThemeChange -theme \"Auto\"\n      }\n      "
                                             ],
                              "link":  "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/darkmode"
                          },
    "WPFToggleShowExt":  {
                             "Content":  "File Explorer File Extensions",
                             "Description":  "Shows .file extensions in Explorer (.exe, .png, etc.)",
                             "category":  "Customize Preferences",
                             "panel":  "2",
                             "Type":  "Toggle",
                             "registry":  [
                                              {
                                                  "Path":  "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
                                                  "Name":  "HideFileExt",
                                                  "Value":  "0",
                                                  "Type":  "DWord",
                                                  "OriginalValue":  "1",
                                                  "DefaultState":  "false"
                                              }
                                          ],
                             "InvokeScript":  [
                                                  "\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\n      "
                                              ],
                             "UndoScript":  [
                                                "\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\n      "
                                            ],
                             "link":  "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/showext"
                         },
    "WPFToggleHiddenFiles":  {
                                 "Content":  "File Explorer Hidden Files",
                                 "Description":  "Reveals hidden files in Explorer.",
                                 "category":  "Customize Preferences",
                                 "panel":  "2",
                                 "Type":  "Toggle",
                                 "registry":  [
                                                  {
                                                      "Path":  "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
                                                      "Name":  "Hidden",
                                                      "Value":  "1",
                                                      "Type":  "DWord",
                                                      "OriginalValue":  "0",
                                                      "DefaultState":  "false"
                                                  }
                                              ],
                                 "InvokeScript":  [
                                                      "\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\n      "
                                                  ],
                                 "UndoScript":  [
                                                    "\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\n      "
                                                ],
                                 "link":  "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/hiddenfiles"
                             },
    "WPFToggleVerboseLogon":  {
                                  "Content":  "Logon Verbose Mode",
                                  "Description":  "Show detailed messages during startup/shutdown.",
                                  "category":  "Customize Preferences",
                                  "panel":  "2",
                                  "Type":  "Toggle",
                                  "registry":  [
                                                   {
                                                       "Path":  "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\System",
                                                       "Name":  "VerboseStatus",
                                                       "Value":  "1",
                                                       "Type":  "DWord",
                                                       "OriginalValue":  "0",
                                                       "DefaultState":  "false"
                                                   }
                                               ],
                                  "link":  "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/verboselogon"
                              },
    "WPFToggleNewOutlook":  {
                                "Content":  "Microsoft Outlook New Version",
                                "Description":  "This will ensure the new Outlook application is used.",
                                "category":  "Customize Preferences",
                                "panel":  "2",
                                "Type":  "Toggle",
                                "registry":  [
                                                 {
                                                     "Path":  "HKCU:\\SOFTWARE\\Microsoft\\Office\\16.0\\Outlook\\Preferences",
                                                     "Name":  "UseNewOutlook",
                                                     "Value":  "1",
                                                     "Type":  "DWord",
                                                     "OriginalValue":  "0",
                                                     "DefaultState":  "true"
                                                 },
                                                 {
                                                     "Path":  "HKCU:\\Software\\Microsoft\\Office\\16.0\\Outlook\\Options\\General",
                                                     "Name":  "HideNewOutlookToggle",
                                                     "Value":  "0",
                                                     "Type":  "DWord",
                                                     "OriginalValue":  "1",
                                                     "DefaultState":  "true"
                                                 },
                                                 {
                                                     "Path":  "HKCU:\\Software\\Policies\\Microsoft\\Office\\16.0\\Outlook\\Options\\General",
                                                     "Name":  "DoNewOutlookAutoMigration",
                                                     "Value":  "0",
                                                     "Type":  "DWord",
                                                     "OriginalValue":  "0",
                                                     "DefaultState":  "false"
                                                 },
                                                 {
                                                     "Path":  "HKCU:\\Software\\Policies\\Microsoft\\Office\\16.0\\Outlook\\Preferences",
                                                     "Name":  "NewOutlookMigrationUserSetting",
                                                     "Value":  "0",
                                                     "Type":  "DWord",
                                                     "OriginalValue":  "\u003cRemoveEntry\u003e",
                                                     "DefaultState":  "true"
                                                 }
                                             ],
                                "link":  "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/newoutlook"
                            },
    "WPFToggleScrollbars":  {
                                "Content":  "Scrollbars Always Visible",
                                "Description":  "If enabled, scrollbars will always be visible. If disabled, Windows will automatically hide scrollbars when not in use.",
                                "category":  "Customize Preferences",
                                "panel":  "2",
                                "Type":  "Toggle",
                                "registry":  [
                                                 {
                                                     "Path":  "HKCU:\\Control Panel\\Accessibility",
                                                     "Name":  "DynamicScrollbars",
                                                     "Value":  "0",
                                                     "Type":  "DWord",
                                                     "OriginalValue":  "1",
                                                     "DefaultState":  "false"
                                                 }
                                             ],
                                "link":  "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/scrollbars"
                            },
    "WPFMultiplaneOverlay":  {
                                 "Content":  "Multiplane Overlay",
                                 "Description":  "Multiplane Overlay composes multiple image layers, which can sometimes cause issues with graphics cards. Changes to this preference are applied immediately.",
                                 "category":  "Customize Preferences",
                                 "panel":  "2",
                                 "Type":  "Combobox",
                                 "ComboItems":  "Enabled|Disabled (Compatibility)|Fully Disabled",
                                 "ComboDescriptions":  {
                                                           "Enabled":  "Uses Windows\u0027 default overlay behavior.",
                                                           "Disabled (Compatibility)":  "Disables MPO using OverlayTestMode=5, the less aggressive compatibility method.",
                                                           "Fully Disabled":  "Disables MPO using OverlayTestMode=5 and DisableOverlays=1, the more aggressive method."
                                                       },
                                 "registry":  [
                                                  {
                                                      "Path":  "HKLM:\\SOFTWARE\\Microsoft\\Windows\\Dwm",
                                                      "Name":  "OverlayTestMode",
                                                      "Type":  "DWord",
                                                      "DefaultValue":  "0",
                                                      "Values":  {
                                                                     "Enabled":  "\u003cRemoveEntry\u003e",
                                                                     "Disabled (Compatibility)":  "5",
                                                                     "Fully Disabled":  "5"
                                                                 }
                                                  },
                                                  {
                                                      "Path":  "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\GraphicsDrivers",
                                                      "Name":  "DisableOverlays",
                                                      "Type":  "DWord",
                                                      "DefaultValue":  "0",
                                                      "Values":  {
                                                                     "Enabled":  "\u003cRemoveEntry\u003e",
                                                                     "Disabled (Compatibility)":  "\u003cRemoveEntry\u003e",
                                                                     "Fully Disabled":  "1"
                                                                 }
                                                  }
                                              ],
                                 "link":  "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/multiplaneoverlay"
                             },
    "WPFToggleMouseAcceleration":  {
                                       "Content":  "Mouse Acceleration",
                                       "Description":  "Makes it so Cursor movement is affected by the speed of your physical mouse movements.",
                                       "category":  "Customize Preferences",
                                       "panel":  "2",
                                       "Type":  "Toggle",
                                       "registry":  [
                                                        {
                                                            "Path":  "HKCU:\\Control Panel\\Mouse",
                                                            "Name":  "MouseSpeed",
                                                            "Value":  "1",
                                                            "Type":  "DWord",
                                                            "OriginalValue":  "0",
                                                            "DefaultState":  "true"
                                                        },
                                                        {
                                                            "Path":  "HKCU:\\Control Panel\\Mouse",
                                                            "Name":  "MouseThreshold1",
                                                            "Value":  "6",
                                                            "Type":  "DWord",
                                                            "OriginalValue":  "0",
                                                            "DefaultState":  "true"
                                                        },
                                                        {
                                                            "Path":  "HKCU:\\Control Panel\\Mouse",
                                                            "Name":  "MouseThreshold2",
                                                            "Value":  "10",
                                                            "Type":  "DWord",
                                                            "OriginalValue":  "0",
                                                            "DefaultState":  "true"
                                                        }
                                                    ],
                                       "link":  "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/mouseacceleration"
                                   },
    "WPFToggleNumLock":  {
                             "Content":  "Num Lock on Startup",
                             "Description":  "Toggle the Num Lock key state when your computer starts.",
                             "category":  "Customize Preferences",
                             "panel":  "2",
                             "Type":  "Toggle",
                             "registry":  [
                                              {
                                                  "Path":  "HKU:\\.Default\\Control Panel\\Keyboard",
                                                  "Name":  "InitialKeyboardIndicators",
                                                  "Value":  "2",
                                                  "Type":  "String",
                                                  "OriginalValue":  "0",
                                                  "DefaultState":  "false"
                                              },
                                              {
                                                  "Path":  "HKCU:\\Control Panel\\Keyboard",
                                                  "Name":  "InitialKeyboardIndicators",
                                                  "Value":  "2",
                                                  "Type":  "String",
                                                  "OriginalValue":  "0",
                                                  "DefaultState":  "false"
                                              }
                                          ],
                             "link":  "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/numlock"
                         },
    "WPFToggleWindowSnapping":  {
                                    "Content":  "Window Snapping",
                                    "Description":  "Toggles the window snapping feature when dragging windows.",
                                    "category":  "Customize Preferences",
                                    "panel":  "2",
                                    "Type":  "Toggle",
                                    "registry":  [
                                                     {
                                                         "Path":  "HKCU:\\Control Panel\\Desktop",
                                                         "Name":  "WindowArrangementActive",
                                                         "Value":  "1",
                                                         "Type":  "String",
                                                         "OriginalValue":  "0",
                                                         "DefaultState":  "true"
                                                     }
                                                 ],
                                    "link":  "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/windowsnapping"
                                },
    "WPFToggleStandbyFix":  {
                                "Content":  "S0 Sleep Network Connectivity",
                                "Description":  "Toggles network connectivity during S0 Sleep which is low power idle in modern laptops.",
                                "category":  "Customize Preferences",
                                "panel":  "2",
                                "Type":  "Toggle",
                                "registry":  [
                                                 {
                                                     "Path":  "HKCU:\\SOFTWARE\\Policies\\Microsoft\\Power\\PowerSettings\\f15576e8-98b7-4186-b944-eafa664402d9",
                                                     "Name":  "ACSettingIndex",
                                                     "Value":  "1",
                                                     "Type":  "DWord",
                                                     "OriginalValue":  "0",
                                                     "DefaultState":  "true"
                                                 }
                                             ],
                                "link":  "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/standbyfix"
                            },
    "WPFToggleS3Sleep":  {
                             "Content":  "S3 Sleep",
                             "Description":  "Toggles between Modern Standby and S3 Sleep, which cuts off power to the CPU while continuing to refresh the memory.",
                             "category":  "Customize Preferences",
                             "panel":  "2",
                             "Type":  "Toggle",
                             "registry":  [
                                              {
                                                  "Path":  "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Power",
                                                  "Name":  "PlatformAoAcOverride",
                                                  "Value":  "0",
                                                  "Type":  "DWord",
                                                  "OriginalValue":  "\u003cRemoveEntry\u003e",
                                                  "DefaultState":  "false"
                                              }
                                          ],
                             "link":  "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/s3sleep"
                         },
    "WPFToggleHideSettingsHome":  {
                                      "Content":  "Settings Home Page",
                                      "Description":  "Toggles the Home Page in the Windows Settings app.",
                                      "category":  "Customize Preferences",
                                      "panel":  "2",
                                      "Type":  "Toggle",
                                      "registry":  [
                                                       {
                                                           "Path":  "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Policies\\Explorer",
                                                           "Name":  "SettingsPageVisibility",
                                                           "Value":  "show:home",
                                                           "Type":  "String",
                                                           "OriginalValue":  "hide:home",
                                                           "DefaultState":  "true"
                                                       }
                                                   ],
                                      "link":  "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/hidesettingshome"
                                  },
    "WPFToggleBingSearch":  {
                                "Content":  "Start Menu Bing Search",
                                "Description":  "Toggles Bing web search results in Windows Search.",
                                "category":  "Customize Preferences",
                                "panel":  "2",
                                "Type":  "Toggle",
                                "registry":  [
                                                 {
                                                     "Path":  "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Search",
                                                     "Name":  "BingSearchEnabled",
                                                     "Value":  "1",
                                                     "Type":  "DWord",
                                                     "OriginalValue":  "0",
                                                     "DefaultState":  "true"
                                                 }
                                             ],
                                "link":  "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/bingsearch"
                            },
    "WPFToggleLoginBlur":  {
                               "Content":  "Logon Screen Acrylic Blur",
                               "Description":  "Toggles the acrylic blur effect on login screen background.",
                               "category":  "Customize Preferences",
                               "panel":  "2",
                               "Type":  "Toggle",
                               "registry":  [
                                                {
                                                    "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\System",
                                                    "Name":  "DisableAcrylicBackgroundOnLogon",
                                                    "Value":  "0",
                                                    "Type":  "DWord",
                                                    "OriginalValue":  "1",
                                                    "DefaultState":  "true"
                                                }
                                            ],
                               "link":  "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/loginblur"
                           },
    "WPFToggleDisableLockscreen":  {
                                       "Content":  "Lock Screen - Disable",
                                       "Description":  "Skips the lock screen entirely and goes directly to the sign-in screen on boot and wake.",
                                       "category":  "Customize Preferences",
                                       "panel":  "2",
                                       "Type":  "Toggle",
                                       "registry":  [
                                                        {
                                                            "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\Personalization",
                                                            "Name":  "NoLockScreen",
                                                            "Value":  "1",
                                                            "Type":  "DWord",
                                                            "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                        }
                                                    ],
                                       "link":  "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/disablelockscreen"
                                   },
    "WPFToggleStartMenuRecommendations":  {
                                              "Content":  "Start Menu Recommendations",
                                              "Description":  "Toggles the recommendations section in the Start Menu. WARNING: This will also disable Windows Spotlight on your Lock Screen as a side effect.",
                                              "category":  "Customize Preferences",
                                              "panel":  "2",
                                              "Type":  "Toggle",
                                              "registry":  [
                                                               {
                                                                   "Path":  "HKLM:\\SOFTWARE\\Microsoft\\PolicyManager\\current\\device\\Start",
                                                                   "Name":  "HideRecommendedSection",
                                                                   "Value":  "0",
                                                                   "Type":  "DWord",
                                                                   "OriginalValue":  "1",
                                                                   "DefaultState":  "true"
                                                               },
                                                               {
                                                                   "Path":  "HKLM:\\SOFTWARE\\Microsoft\\PolicyManager\\current\\device\\Education",
                                                                   "Name":  "IsEducationEnvironment",
                                                                   "Value":  "0",
                                                                   "Type":  "DWord",
                                                                   "OriginalValue":  "1",
                                                                   "DefaultState":  "true"
                                                               },
                                                               {
                                                                   "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\Explorer",
                                                                   "Name":  "HideRecommendedSection",
                                                                   "Value":  "0",
                                                                   "Type":  "DWord",
                                                                   "OriginalValue":  "1",
                                                                   "DefaultState":  "true"
                                                               }
                                                           ],
                                              "InvokeScript":  [
                                                                   "\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\n      "
                                                               ],
                                              "UndoScript":  [
                                                                 "\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\n      "
                                                             ],
                                              "link":  "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/startmenurecommendations"
                                          },
    "WPFToggleStickyKeys":  {
                                "Content":  "Sticky Keys",
                                "Description":  "Toggles the Sticky Keys, which activate when clicking shift rapidly.",
                                "category":  "Customize Preferences",
                                "panel":  "2",
                                "Type":  "Toggle",
                                "registry":  [
                                                 {
                                                     "Path":  "HKCU:\\Control Panel\\Accessibility\\StickyKeys",
                                                     "Name":  "Flags",
                                                     "Value":  "506",
                                                     "Type":  "DWord",
                                                     "OriginalValue":  "58",
                                                     "DefaultState":  "true"
                                                 }
                                             ],
                                "link":  "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/stickykeys"
                            },
    "WPFToggleTaskbarAlignment":  {
                                      "Content":  "Taskbar Centered Icons",
                                      "Description":  "Toggles the Taskbar alignment either to the left or center.",
                                      "category":  "Customize Preferences",
                                      "panel":  "2",
                                      "Type":  "Toggle",
                                      "registry":  [
                                                       {
                                                           "Path":  "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
                                                           "Name":  "TaskbarAl",
                                                           "Value":  "1",
                                                           "Type":  "DWord",
                                                           "OriginalValue":  "0",
                                                           "DefaultState":  "true"
                                                       }
                                                   ],
                                      "InvokeScript":  [
                                                           "\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\n      "
                                                       ],
                                      "UndoScript":  [
                                                         "\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\n      "
                                                     ],
                                      "link":  "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/taskbaralignment"
                                  },
    "WPFToggleTaskbarSearch":  {
                                   "Content":  "Taskbar Search Icon",
                                   "Description":  "Toggles the Search Button on the Taskbar.",
                                   "category":  "Customize Preferences",
                                   "panel":  "2",
                                   "Type":  "Toggle",
                                   "registry":  [
                                                    {
                                                        "Path":  "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Search",
                                                        "Name":  "SearchboxTaskbarMode",
                                                        "Value":  "1",
                                                        "Type":  "DWord",
                                                        "OriginalValue":  "0",
                                                        "DefaultState":  "true"
                                                    }
                                                ],
                                   "link":  "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/taskbarsearch"
                               },
    "WPFToggleTaskView":  {
                              "Content":  "Taskbar Task View Icon",
                              "Description":  "Toggles the Task View Button in the Taskbar.",
                              "category":  "Customize Preferences",
                              "panel":  "2",
                              "Type":  "Toggle",
                              "registry":  [
                                               {
                                                   "Path":  "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
                                                   "Name":  "ShowTaskViewButton",
                                                   "Value":  "1",
                                                   "Type":  "DWord",
                                                   "OriginalValue":  "0",
                                                   "DefaultState":  "true"
                                               }
                                           ],
                              "link":  "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/taskview"
                          },
    "WPFToggleGameMode":  {
                              "Content":  "Game Mode",
                              "Description":  "Toggles Windows prioritizes gaming performance by allocating system resources to games.",
                              "category":  "Customize Preferences",
                              "panel":  "2",
                              "Type":  "Toggle",
                              "registry":  [
                                               {
                                                   "Path":  "HKCU:\\Software\\Microsoft\\GameBar",
                                                   "Name":  "AllowAutoGameMode",
                                                   "Value":  "1",
                                                   "Type":  "DWord",
                                                   "OriginalValue":  "0",
                                                   "DefaultState":  "true"
                                               },
                                               {
                                                   "Path":  "HKCU:\\Software\\Microsoft\\GameBar",
                                                   "Name":  "AutoGameModeEnabled",
                                                   "Value":  "1",
                                                   "Type":  "DWord",
                                                   "OriginalValue":  "0",
                                                   "DefaultState":  "true"
                                               }
                                           ],
                              "link":  "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/gamemode"
                          },
    "WPFToggleGameDVR":  {
                             "Content":  "Game DVR Background Recording",
                             "Description":  "Toggles Xbox Game Bar background capture (Record what happened). Turning it off avoids continuous video encoding while gaming. Screenshots and manual recording are not removed.",
                             "category":  "Customize Preferences",
                             "panel":  "2",
                             "Type":  "Toggle",
                             "registry":  [
                                              {
                                                  "Path":  "HKCU:\\System\\GameConfigStore",
                                                  "Name":  "GameDVR_Enabled",
                                                  "Value":  "1",
                                                  "Type":  "DWord",
                                                  "OriginalValue":  "0",
                                                  "DefaultState":  "true"
                                              },
                                              {
                                                  "Path":  "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\GameDVR",
                                                  "Name":  "AppCaptureEnabled",
                                                  "Value":  "1",
                                                  "Type":  "DWord",
                                                  "OriginalValue":  "0",
                                                  "DefaultState":  "true"
                                              }
                                          ],
                             "link":  "https://support.microsoft.com/en-us/windows/record-a-game-clip-on-your-pc-with-xbox-game-bar-2f477001-54df-4a17-b1fc-e4a4cb4ac28c"
                         },
    "WPFToggleHAGS":  {
                          "Content":  "Hardware-Accelerated GPU Scheduling",
                          "Description":  "Toggles GPU scheduling by the graphics card (HwSchMode). Requires a WDDM 2.7+ GPU and driver, and a restart. Results vary by GPU and game; Windows ignores it on unsupported hardware.",
                          "category":  "Customize Preferences",
                          "panel":  "2",
                          "Type":  "Toggle",
                          "registry":  [
                                           {
                                               "Path":  "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\GraphicsDrivers",
                                               "Name":  "HwSchMode",
                                               "Value":  "2",
                                               "Type":  "DWord",
                                               "OriginalValue":  "1",
                                               "DefaultState":  "false"
                                           }
                                       ],
                          "link":  "https://devblogs.microsoft.com/directx/hardware-accelerated-gpu-scheduling/"
                      },
    "WPFToggleGamingMultimediaProfile":  {
                                             "Content":  "Multimedia Gaming Profile",
                                             "Description":  "Toggles the MMCSS system profile: reserves 10% CPU for background tasks instead of 20% (SystemResponsiveness) and turns off multimedia network throttling (NetworkThrottlingIndex 0xFFFFFFFF). Turning it off restores the Windows defaults 20 and 10. FPS gains are not guaranteed.",
                                             "category":  "Customize Preferences",
                                             "panel":  "2",
                                             "Type":  "Toggle",
                                             "registry":  [
                                                              {
                                                                  "Path":  "HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Multimedia\\SystemProfile",
                                                                  "Name":  "SystemResponsiveness",
                                                                  "Value":  "10",
                                                                  "Type":  "DWord",
                                                                  "OriginalValue":  "20",
                                                                  "DefaultState":  "false"
                                                              },
                                                              {
                                                                  "Path":  "HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Multimedia\\SystemProfile",
                                                                  "Name":  "NetworkThrottlingIndex",
                                                                  "Value":  "-1",
                                                                  "Type":  "DWord",
                                                                  "OriginalValue":  "10",
                                                                  "DefaultState":  "false"
                                                              }
                                                          ],
                                             "link":  "https://learn.microsoft.com/en-us/windows/win32/procthread/multimedia-class-scheduler-service"
                                         },
    "WPFToggleFastStartup":  {
                                 "Content":  "Fast Startup",
                                 "Description":  "Toggles Fast Startup (HiberbootEnabled). Turning it off makes Shut down perform a full shutdown, so drivers and the kernel start clean; boot can take a few seconds longer. Has no effect while hibernation is disabled.",
                                 "category":  "Customize Preferences",
                                 "panel":  "2",
                                 "Type":  "Toggle",
                                 "registry":  [
                                                  {
                                                      "Path":  "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Power",
                                                      "Name":  "HiberbootEnabled",
                                                      "Value":  "1",
                                                      "Type":  "DWord",
                                                      "OriginalValue":  "0",
                                                      "DefaultState":  "true"
                                                  }
                                              ],
                                 "link":  "https://learn.microsoft.com/en-us/troubleshoot/windows-client/setup-upgrade-and-drivers/fast-startup-causes-hibernation-file-to-be-created"
                             },
    "WPFToggleLongPaths":  {
                               "Content":  "Enable Long Paths",
                               "Description":  "Toggles support for file paths longer than 260 characters in Explorer.",
                               "category":  "Customize Preferences",
                               "panel":  "2",
                               "Type":  "Toggle",
                               "registry":  [
                                                {
                                                    "Path":  "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\FileSystem",
                                                    "Name":  "LongPathsEnabled",
                                                    "Value":  "1",
                                                    "Type":  "DWord",
                                                    "OriginalValue":  "0",
                                                    "DefaultState":  "false"
                                                }
                                            ],
                               "link":  "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/longpaths"
                           },
    "WPFchangedns":  {
                         "Content":  "DNS - Set to:",
                         "category":  "z__Advanced Tweaks - CAUTION",
                         "panel":  "1",
                         "Type":  "Combobox",
                         "ComboItems":  "Default DHCP Fastest Google Cloudflare Cloudflare_Malware Cloudflare_Malware_Adult Open_DNS Quad9 AdGuard_Ads_Trackers AdGuard_Ads_Trackers_Malware_Adult",
                         "link":  "https://winutil.christitus.com/code-reference/tweaks/z--advanced-tweaks---caution/changedns"
                     },
    "WPFAddUltPerf":  {
                          "Content":  "Ultimate Performance Profile - Enable",
                          "category":  "Performance Plans - NOT FOR LAPTOPS",
                          "panel":  "2",
                          "Type":  "Button",
                          "ButtonWidth":  "300",
                          "link":  "https://winutil.christitus.com/code-reference/tweaks/performance-plans---not-for-laptops/addultperf"
                      },
    "WPFRemoveUltPerf":  {
                             "Content":  "Ultimate Performance Profile - Disable",
                             "category":  "Performance Plans - NOT FOR LAPTOPS",
                             "panel":  "2",
                             "Type":  "Button",
                             "ButtonWidth":  "300",
                             "link":  "https://winutil.christitus.com/code-reference/tweaks/performance-plans---not-for-laptops/removeultperf"
                         }
}
'@ | ConvertFrom-Json
$inputXML = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" xmlns:d="http://schemas.microsoft.com/expression/blend/2008" xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" xmlns:local="clr-namespace:WinUtility" WindowStartupLocation="CenterScreen" UseLayoutRounding="True" WindowStyle="SingleBorderWindow" Width="Auto" Height="Auto" MinWidth="800" MinHeight="600" Title="APBOptimizer - Tweaks">
    <WindowChrome.WindowChrome>
        <WindowChrome CaptionHeight="0" CornerRadius="10" UseAeroCaptionButtons="False" />
    </WindowChrome.WindowChrome>
    <Window.Resources>
    <Style TargetType="ToolTip">
        <Setter Property="Background" Value="{DynamicResource ToolTipBackgroundColor}" />
        <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}" />
        <Setter Property="BorderBrush" Value="{DynamicResource BorderColor}" />
        <Setter Property="MaxWidth" Value="{DynamicResource ToolTipWidth}" />
        <Setter Property="BorderThickness" Value="1" />
        <Setter Property="Padding" Value="2" />
        <Setter Property="FontSize" Value="{DynamicResource FontSize}" />
        <Setter Property="FontFamily" Value="{DynamicResource FontFamily}" />
        <!-- This ContentTemplate ensures that the content of the ToolTip wraps text properly for better readability -->
        <Setter Property="ContentTemplate">
            <Setter.Value>
                <DataTemplate>
                    <ContentPresenter Content="{TemplateBinding Content}">
                        <ContentPresenter.Resources>
                            <Style TargetType="TextBlock">
                                <Setter Property="TextWrapping" Value="Wrap" />
                            </Style>
                        </ContentPresenter.Resources>
                    </ContentPresenter>
                </DataTemplate>
            </Setter.Value>
        </Setter>
    </Style>

    <Style TargetType="{x:Type MenuItem}">
        <Setter Property="Background" Value="{DynamicResource MainBackgroundColor}" />
        <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}" />
        <Setter Property="FontSize" Value="{DynamicResource FontSize}" />
        <Setter Property="FontFamily" Value="{DynamicResource FontFamily}" />
        <Setter Property="Padding" Value="5,2,5,2" />
        <Setter Property="BorderThickness" Value="0" />
    </Style>

    <!--Scrollbar Thumbs-->
    <Style x:Key="ScrollThumbs" TargetType="{x:Type Thumb}">
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="{x:Type Thumb}">
                    <Grid Name="Grid">
                        <Rectangle HorizontalAlignment="Stretch" VerticalAlignment="Stretch" Width="Auto" Height="Auto" Fill="Transparent" />
                        <Border Name="Rectangle1" CornerRadius="5" HorizontalAlignment="Stretch" VerticalAlignment="Stretch" Width="Auto" Height="Auto" Background="{TemplateBinding Background}" />
                    </Grid>
                    <ControlTemplate.Triggers>
                        <Trigger Property="Tag" Value="Horizontal">
                            <Setter TargetName="Rectangle1" Property="Width" Value="Auto" />
                            <Setter TargetName="Rectangle1" Property="Height" Value="7" />
                        </Trigger>
                    </ControlTemplate.Triggers>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
    </Style>

    <Style TargetType="TextBlock" x:Key="HoverTextBlockStyle">
        <Setter Property="Foreground" Value="{DynamicResource LinkForegroundColor}" />
        <Setter Property="TextDecorations" Value="Underline" />
        <Style.Triggers>
            <Trigger Property="IsMouseOver" Value="True">
                <Setter Property="Foreground" Value="{DynamicResource LinkHoverForegroundColor}" />
                <Setter Property="TextDecorations" Value="Underline" />
                <Setter Property="Cursor" Value="Hand" />
            </Trigger>
        </Style.Triggers>
    </Style>
    <Style x:Key="AppEntryBorderStyle" TargetType="Border">
        <Setter Property="BorderBrush" Value="Gray" />
        <Setter Property="BorderThickness" Value="{DynamicResource AppEntryBorderThickness}" />
        <Setter Property="CornerRadius" Value="5" />
        <Setter Property="Padding" Value="6,4" />
        <Setter Property="Width" Value="{DynamicResource AppEntryWidth}" />
        <Setter Property="VerticalAlignment" Value="Top" />
        <Setter Property="Margin" Value="{DynamicResource AppEntryMargin}" />
        <Setter Property="Cursor" Value="Hand" />
        <Setter Property="Background" Value="{DynamicResource AppInstallUnselectedColor}" />
    </Style>
    <Style x:Key="AppEntryCheckboxStyle" TargetType="CheckBox">
        <Setter Property="Background" Value="Transparent" />
        <Setter Property="HorizontalAlignment" Value="Left" />
        <Setter Property="VerticalAlignment" Value="Center" />
        <Setter Property="Margin" Value="{DynamicResource AppEntryMargin}" />
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="CheckBox">
                    <ContentPresenter Content="{TemplateBinding Content}" VerticalAlignment="Center" HorizontalAlignment="Left" />
                </ControlTemplate>
            </Setter.Value>
        </Setter>
    </Style>
    <Style x:Key="AppEntryNameStyle" TargetType="TextBlock">
        <Setter Property="FontSize" Value="{DynamicResource AppEntryFontSize}" />
        <Setter Property="FontWeight" Value="Bold" />
        <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}" />
        <Setter Property="VerticalAlignment" Value="Center" />
        <Setter Property="Margin" Value="{DynamicResource AppEntryMargin}" />
        <Setter Property="Background" Value="Transparent" />
    </Style>
    <Style x:Key="AppEntryButtonStyle" TargetType="Button">
        <Setter Property="Width" Value="{DynamicResource IconButtonSize}" />
        <Setter Property="Height" Value="{DynamicResource IconButtonSize}" />
        <Setter Property="Margin" Value="{DynamicResource AppEntryMargin}" />
        <Setter Property="Foreground" Value="{DynamicResource ButtonForegroundColor}" />
        <Setter Property="Background" Value="{DynamicResource ButtonBackgroundColor}" />
        <Setter Property="HorizontalAlignment" Value="Center" />
        <Setter Property="VerticalAlignment" Value="Center" />
        <Setter Property="ContentTemplate">
            <Setter.Value>
                <DataTemplate>
                    <TextBlock Text="{Binding}" FontFamily="Segoe MDL2 Assets" FontSize="{DynamicResource IconFontSize}" Background="Transparent" />
                </DataTemplate>
            </Setter.Value>
        </Setter>
        <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Name="BackgroundBorder" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{DynamicResource ButtonBorderThickness}" CornerRadius="{DynamicResource ButtonCornerRadius}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" />
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundPressedColor}" />
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter Property="Cursor" Value="Hand" />
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundMouseoverColor}" />
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundSelectedColor}" />
                                <Setter Property="Foreground" Value="DimGray" />
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>


    </Style>
    <Style TargetType="Button" x:Key="HoverButtonStyle">
        <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}" />
        <Setter Property="FontWeight" Value="Normal" />
        <Setter Property="FontSize" Value="{DynamicResource ButtonFontSize}" />
        <Setter Property="TextElement.FontFamily" Value="{DynamicResource ButtonFontFamily}" />
        <Setter Property="Background" Value="{DynamicResource MainBackgroundColor}" />
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="Button">
                    <Border Background="{TemplateBinding Background}">
                        <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" />
                    </Border>
                    <ControlTemplate.Triggers>
                        <Trigger Property="IsMouseOver" Value="True">
                            <Setter Property="FontWeight" Value="Bold" />
                            <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}" />
                            <Setter Property="Cursor" Value="Hand" />
                        </Trigger>
                    </ControlTemplate.Triggers>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
    </Style>

    <!--ScrollBars-->
    <Style x:Key="{x:Type ScrollBar}" TargetType="{x:Type ScrollBar}">
        <Setter Property="Stylus.IsFlicksEnabled" Value="false" />
        <Setter Property="Foreground" Value="{DynamicResource ScrollBarBackgroundColor}" />
        <Setter Property="Background" Value="{DynamicResource MainBackgroundColor}" />
        <Setter Property="Width" Value="6" />
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="{x:Type ScrollBar}">
                    <Grid Name="GridRoot" Width="7" Background="{TemplateBinding Background}">
                        <Grid.RowDefinitions>
                            <RowDefinition Height="0.00001*" />
                        </Grid.RowDefinitions>

                        <Track Name="PART_Track" Grid.Row="0" IsDirectionReversed="true" Focusable="false">
                            <Track.Thumb>
                                <Thumb Name="Thumb" Background="{TemplateBinding Foreground}" Style="{DynamicResource ScrollThumbs}" />
                            </Track.Thumb>
                            <Track.IncreaseRepeatButton>
                                <RepeatButton Name="PageUp" Command="ScrollBar.PageDownCommand" Opacity="0" Focusable="false" />
                            </Track.IncreaseRepeatButton>
                            <Track.DecreaseRepeatButton>
                                <RepeatButton Name="PageDown" Command="ScrollBar.PageUpCommand" Opacity="0" Focusable="false" />
                            </Track.DecreaseRepeatButton>
                        </Track>
                    </Grid>

                    <ControlTemplate.Triggers>
                        <Trigger SourceName="Thumb" Property="IsMouseOver" Value="true">
                            <Setter Value="{DynamicResource ScrollBarHoverColor}" TargetName="Thumb" Property="Background" />
                        </Trigger>
                        <Trigger SourceName="Thumb" Property="IsDragging" Value="true">
                            <Setter Value="{DynamicResource ScrollBarDraggingColor}" TargetName="Thumb" Property="Background" />
                        </Trigger>

                        <Trigger Property="IsEnabled" Value="false">
                            <Setter TargetName="Thumb" Property="Visibility" Value="Collapsed" />
                        </Trigger>
                        <Trigger Property="Orientation" Value="Horizontal">
                            <Setter TargetName="GridRoot" Property="LayoutTransform">
                                <Setter.Value>
                                    <RotateTransform Angle="-90" />
                                </Setter.Value>
                            </Setter>
                            <Setter TargetName="PART_Track" Property="LayoutTransform">
                                <Setter.Value>
                                    <RotateTransform Angle="-90" />
                                </Setter.Value>
                            </Setter>
                            <Setter Property="Width" Value="Auto" />
                            <Setter Property="Height" Value="8" />
                            <Setter TargetName="Thumb" Property="Tag" Value="Horizontal" />
                            <Setter TargetName="PageDown" Property="Command" Value="ScrollBar.PageLeftCommand" />
                            <Setter TargetName="PageUp" Property="Command" Value="ScrollBar.PageRightCommand" />
                        </Trigger>
                    </ControlTemplate.Triggers>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
        </Style>
        <Style x:Key="ComboBoxToggleButtonStyle" TargetType="ToggleButton">
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ToggleButton">
                        <Border Background="{TemplateBinding Background}" BorderThickness="0">
                            <ContentPresenter />
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="ComboBox">
            <Setter Property="Foreground" Value="{DynamicResource ComboBoxForegroundColor}" />
            <Setter Property="Background" Value="{DynamicResource ComboBoxBackgroundColor}" />
            <Setter Property="MinWidth" Value="{DynamicResource ButtonWidth}" />
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ComboBox">
                        <Grid>
                            <Border Name="OuterBorder" BorderBrush="{DynamicResource BorderColor}" BorderThickness="1" CornerRadius="{DynamicResource ButtonCornerRadius}" Background="{TemplateBinding Background}">
                                <ToggleButton Name="ToggleButton" Style="{StaticResource ComboBoxToggleButtonStyle}" Background="Transparent" BorderThickness="0" IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}" ClickMode="Press">
                                    <Grid>
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="*" />
                                            <ColumnDefinition Width="Auto" />
                                        </Grid.ColumnDefinitions>
                                        <TextBlock Grid.Column="0" Text="{TemplateBinding SelectionBoxItem}" Foreground="{TemplateBinding Foreground}" Background="Transparent" HorizontalAlignment="Left" VerticalAlignment="Center" Margin="6,3,2,3" />
                                        <Path Grid.Column="1" Data="M 0,0 L 8,0 L 4,5 Z" Fill="{TemplateBinding Foreground}" Width="8" Height="5" VerticalAlignment="Center" HorizontalAlignment="Center" Stretch="Uniform" Margin="4,0,6,0" />
                                    </Grid>
                                </ToggleButton>
                            </Border>
                            <Popup Name="Popup" IsOpen="{TemplateBinding IsDropDownOpen}" Placement="Bottom" Focusable="False" AllowsTransparency="True" PopupAnimation="Slide">
                                <Border Name="DropDownBorder" MinWidth="{Binding ActualWidth, RelativeSource={RelativeSource TemplatedParent}}" Background="{TemplateBinding Background}" BorderBrush="{DynamicResource BorderColor}" BorderThickness="1" CornerRadius="4">
                                    <ScrollViewer>
                                        <!-- Stretched, so an item's highlight spans the popup rather than just its text -->
                                        <ItemsPresenter HorizontalAlignment="Stretch" Margin="4,2" />
                                    </ScrollViewer>
                                </Border>
                            </Popup>
                        </Grid>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="ComboBoxItem">
            <!-- Transparent rather than its own colour: the item used to paint one background and
                 the popup another, which read as a stack of labels on a mismatched sheet -->
            <Setter Property="Background" Value="Transparent" />
            <Setter Property="Foreground" Value="{DynamicResource ComboBoxForegroundColor}" />
            <Setter Property="HorizontalContentAlignment" Value="Stretch" />
            <Setter Property="Padding" Value="6,3" />
            <Setter Property="ContentTemplate">
                <Setter.Value>
                    <DataTemplate>
                        <TextBlock Text="{Binding}" Background="Transparent" Foreground="{Binding Foreground, RelativeSource={RelativeSource AncestorType=ComboBoxItem}}" />
                    </DataTemplate>
                </Setter.Value>
            </Setter>
            <Style.Triggers>
                <Trigger Property="IsHighlighted" Value="True">
                    <Setter Property="Background" Value="{DynamicResource ButtonBackgroundMouseoverColor}" />
                </Trigger>
                <Trigger Property="IsSelected" Value="True">
                    <Setter Property="Background" Value="{DynamicResource ButtonBackgroundSelectedColor}" />
                </Trigger>
            </Style.Triggers>
        </Style>
        <Style TargetType="Label">
            <Setter Property="Foreground" Value="{DynamicResource LabelboxForegroundColor}" />
            <Setter Property="Background" Value="{DynamicResource LabelBackgroundColor}" />
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}" />
        </Style>

        <!-- TextBlock template -->
        <Style TargetType="TextBlock">
            <Setter Property="FontSize" Value="{DynamicResource FontSize}" />
            <Setter Property="Foreground" Value="{DynamicResource LabelboxForegroundColor}" />
            <Setter Property="Background" Value="{DynamicResource LabelBackgroundColor}" />
        </Style>
        <Style x:Key="TabToggleButton" TargetType="{x:Type ToggleButton}">
            <Setter Property="Margin" Value="{DynamicResource ButtonMargin}" />
            <Setter Property="Content" Value="" />
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}" />
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ToggleButton">
                        <Border Name="ButtonGlow" Background="{TemplateBinding Background}" BorderBrush="{DynamicResource ButtonForegroundColor}" BorderThickness="{DynamicResource ButtonBorderThickness}" CornerRadius="{DynamicResource ButtonCornerRadius}">
                            <Border Name="BackgroundBorder" Background="{TemplateBinding Background}" BorderBrush="{DynamicResource ButtonBackgroundColor}" BorderThickness="{DynamicResource ButtonBorderThickness}" CornerRadius="{DynamicResource ButtonCornerRadius}">
                                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="10,2,10,2" />
                            </Border>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundMouseoverColor}" />
                                <Setter Property="Effect">
                                    <Setter.Value>
                                        <DropShadowEffect Opacity="1" ShadowDepth="5" Color="{DynamicResource CButtonBackgroundMouseoverColor}" Direction="-100" BlurRadius="15" />
                                    </Setter.Value>
                                </Setter>
                                <Setter Property="Panel.ZIndex" Value="2000" />
                            </Trigger>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter Property="BorderBrush" Value="Pink" />
                                <Setter Property="BorderThickness" Value="2" />
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundSelectedColor}" />
                                <Setter Property="Effect">
                                    <Setter.Value>
                                        <DropShadowEffect Opacity="1" ShadowDepth="2" Color="{DynamicResource CButtonBackgroundMouseoverColor}" Direction="-111" BlurRadius="10" />
                                    </Setter.Value>
                                </Setter>
                            </Trigger>
                            <Trigger Property="IsChecked" Value="False">
                                <Setter Property="BorderBrush" Value="Transparent" />
                                <Setter Property="BorderThickness" Value="{DynamicResource ButtonBorderThickness}" />
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <!-- Button Template -->
        <Style TargetType="Button">
            <Setter Property="Margin" Value="{DynamicResource ButtonMargin}" />
            <Setter Property="Foreground" Value="{DynamicResource ButtonForegroundColor}" />
            <Setter Property="Background" Value="{DynamicResource ButtonBackgroundColor}" />
            <Setter Property="Height" Value="{DynamicResource ButtonHeight}" />
            <Setter Property="Width" Value="{DynamicResource ButtonWidth}" />
            <Setter Property="FontSize" Value="{DynamicResource ButtonFontSize}" />
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}" />
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Name="BackgroundBorder" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{DynamicResource ButtonBorderThickness}" CornerRadius="{DynamicResource ButtonCornerRadius}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="10,2,10,2" />
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundPressedColor}" />
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundMouseoverColor}" />
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundSelectedColor}" />
                                <Setter Property="Foreground" Value="DimGray" />
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="ToggleButtonStyle" TargetType="ToggleButton">
            <Setter Property="Margin" Value="{DynamicResource ButtonMargin}" />
            <Setter Property="Foreground" Value="{DynamicResource ButtonForegroundColor}" />
            <Setter Property="Background" Value="{DynamicResource ButtonBackgroundColor}" />
            <Setter Property="Height" Value="{DynamicResource ButtonHeight}" />
            <Setter Property="Width" Value="{DynamicResource ButtonWidth}" />
            <Setter Property="FontSize" Value="{DynamicResource ButtonFontSize}" />
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}" />
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ToggleButton">
                        <Border Name="BackgroundBorder" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{DynamicResource ButtonBorderThickness}" CornerRadius="{DynamicResource ButtonCornerRadius}">
                            <Grid>
                                <!-- Toggle Dot Background -->
                                <Ellipse Width="8" Height="16" Fill="{DynamicResource ToggleButtonOnColor}" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,3,5,0" />

                                <!-- Toggle Dot with hover grow effect -->
                                <Ellipse Name="ToggleDot" Width="8" Height="8" Fill="{DynamicResource ButtonForegroundColor}" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,3,5,0" RenderTransformOrigin="0.5,0.5">
                                    <Ellipse.RenderTransform>
                                        <ScaleTransform ScaleX="1" ScaleY="1" />
                                    </Ellipse.RenderTransform>
                                </Ellipse>

                                <!-- Content Presenter -->
                                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="10,2,10,2" />
                            </Grid>
                        </Border>

                        <!-- Triggers for ToggleButton states -->
                        <ControlTemplate.Triggers>
                            <!-- Hover effect -->
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundMouseoverColor}" />
                                <Trigger.EnterActions>
                                    <BeginStoryboard>
                                        <Storyboard>
                                            <!-- Animation to grow the dot when hovered -->
                                            <DoubleAnimation Storyboard.TargetName="ToggleDot" Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)" To="1.2" Duration="0:0:0.1" />
                                            <DoubleAnimation Storyboard.TargetName="ToggleDot" Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)" To="1.2" Duration="0:0:0.1" />
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.EnterActions>
                                <Trigger.ExitActions>
                                    <BeginStoryboard>
                                        <Storyboard>
                                            <!-- Animation to shrink the dot back to original size when not hovered -->
                                            <DoubleAnimation Storyboard.TargetName="ToggleDot" Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)" To="1.0" Duration="0:0:0.1" />
                                            <DoubleAnimation Storyboard.TargetName="ToggleDot" Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)" To="1.0" Duration="0:0:0.1" />
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.ExitActions>
                            </Trigger>

                            <!-- IsChecked state -->
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="ToggleDot" Property="VerticalAlignment" Value="Bottom" />
                                <Setter TargetName="ToggleDot" Property="Margin" Value="0,0,5,3" />
                            </Trigger>

                            <!-- IsEnabled state -->
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundSelectedColor}" />
                                <Setter Property="Foreground" Value="DimGray" />
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="SearchBarClearButtonStyle" TargetType="Button">
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}" />
            <Setter Property="FontSize" Value="{DynamicResource SearchBarClearButtonFontSize}" />
            <Setter Property="Content" Value="X" />
            <Setter Property="Height" Value="{DynamicResource SearchBarClearButtonFontSize}" />
            <Setter Property="Width" Value="{DynamicResource SearchBarClearButtonFontSize}" />
            <Setter Property="Background" Value="Transparent" />
            <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}" />
            <Setter Property="Padding" Value="0" />
            <Setter Property="BorderBrush" Value="Transparent" />
            <Setter Property="BorderThickness" Value="0" />
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Foreground" Value="Red" />
                    <Setter Property="Background" Value="Transparent" />
                    <Setter Property="BorderThickness" Value="10" />
                    <Setter Property="Cursor" Value="Hand" />
                </Trigger>
            </Style.Triggers>
        </Style>
        <!-- Frameless triangle for compact, nested tweak groups. -->
        <Style x:Key="ServiceGroupExpanderStyle" TargetType="Button">
            <Setter Property="Width" Value="12" />
            <Setter Property="Height" Value="16" />
            <Setter Property="Padding" Value="0" />
            <Setter Property="Cursor" Value="Hand" />
            <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}" />
            <Setter Property="Background" Value="Transparent" />
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Background="Transparent">
                            <!-- Path geometry has a centered bounding box; font glyphs
                                 shift with the baseline and appear too low. -->
                            <Path Name="Triangle" Width="8" Height="8" Stretch="None"
                                  Fill="{TemplateBinding Foreground}"
                                  HorizontalAlignment="Center" VerticalAlignment="Center"
                                  Data="M 1,0 L 7,4 L 1,8 Z" />
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="Content" Value="Expanded">
                                <Setter TargetName="Triangle" Property="Data" Value="M 0,1 L 8,1 L 4,7 Z" />
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Foreground" Value="{DynamicResource ToggleButtonOnColor}" />
                </Trigger>
            </Style.Triggers>
        </Style>
        <!-- Checkbox template -->
        <Style TargetType="CheckBox">
            <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}" />
            <Setter Property="Background" Value="{DynamicResource MainBackgroundColor}" />
            <Setter Property="FontSize" Value="{DynamicResource FontSize}" />
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}" />
            <Setter Property="TextElement.FontFamily" Value="{DynamicResource FontFamily}" />
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="CheckBox">
                        <Grid Background="{TemplateBinding Background}" Margin="{DynamicResource CheckBoxMargin}">
                            <BulletDecorator Background="Transparent">
                                <BulletDecorator.Bullet>
                                    <Grid Width="{DynamicResource CheckBoxBulletDecoratorSize}" Height="{DynamicResource CheckBoxBulletDecoratorSize}">
                                        <Border Name="Border" BorderBrush="{TemplateBinding BorderBrush}" Background="{DynamicResource ButtonBackgroundColor}" BorderThickness="1" Width="{DynamicResource CheckBoxBulletDecoratorSize *0.85}" Height="{DynamicResource CheckBoxBulletDecoratorSize *0.85}" Margin="1" SnapsToDevicePixels="True" />
                                        <Viewbox Name="CheckMarkContainer" Width="{DynamicResource CheckBoxBulletDecoratorSize}" Height="{DynamicResource CheckBoxBulletDecoratorSize}" HorizontalAlignment="Center" VerticalAlignment="Center" Visibility="Collapsed">
                                            <Path Name="CheckMark" Stroke="{DynamicResource ToggleButtonOnColor}" StrokeThickness="1.5" Data="M 0 5 L 5 10 L 12 0" Stretch="Uniform" />
                                        </Viewbox>
                                    </Grid>
                                </BulletDecorator.Bullet>
                                <ContentPresenter Margin="4,0,0,0" HorizontalAlignment="Left" VerticalAlignment="Center" RecognizesAccessKey="True" />
                            </BulletDecorator>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="CheckMarkContainer" Property="Visibility" Value="Visible" />
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <!--Setter TargetName="Border" Property="Background" Value="{DynamicResource ButtonBackgroundPressedColor}"/-->
                                <Setter Property="Foreground" Value="{DynamicResource ButtonBackgroundPressedColor}" />
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                 </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="RadioButton">
            <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}" />
            <Setter Property="Background" Value="{DynamicResource MainBackgroundColor}" />
            <Setter Property="FontSize" Value="{DynamicResource FontSize}" />
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}" />
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="RadioButton">
                        <StackPanel Orientation="Horizontal" Margin="{DynamicResource CheckBoxMargin}">
                            <Viewbox Width="{DynamicResource CheckBoxBulletDecoratorSize}" Height="{DynamicResource CheckBoxBulletDecoratorSize}">
                                <Grid Width="14" Height="14">
                                    <Ellipse Name="OuterCircle" Stroke="{DynamicResource ToggleButtonOffColor}" Fill="{DynamicResource ButtonBackgroundColor}" StrokeThickness="1" Width="14" Height="14" SnapsToDevicePixels="True" />
                                    <Ellipse Name="InnerCircle" Fill="{DynamicResource ToggleButtonOnColor}" Width="8" Height="8" Visibility="Collapsed" HorizontalAlignment="Center" VerticalAlignment="Center" />
                                </Grid>
                            </Viewbox>
                            <ContentPresenter Margin="4,0,0,0" VerticalAlignment="Center" RecognizesAccessKey="True" />
                        </StackPanel>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="InnerCircle" Property="Visibility" Value="Visible" />
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="OuterCircle" Property="Stroke" Value="{DynamicResource ToggleButtonOnColor}" />
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="ToggleSwitchStyle" TargetType="CheckBox">
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="CheckBox">
                        <Grid>
                            <Border Width="45" Height="20" Background="#555555" CornerRadius="10" Margin="5,0" />
                            <Border Name="WPFToggleSwitchButton" Width="25" Height="25" Background="Black" CornerRadius="12.5" HorizontalAlignment="Left" />
                            <ContentPresenter Name="WPFToggleSwitchContent" Margin="10,0,0,0" Content="{TemplateBinding Content}" VerticalAlignment="Center" />
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsChecked" Value="false">
                                <Trigger.ExitActions>
                                    <RemoveStoryboard BeginStoryboardName="WPFToggleSwitchLeft" />
                                    <BeginStoryboard Name="WPFToggleSwitchRight">
                                        <Storyboard>
                                            <ThicknessAnimation Storyboard.TargetProperty="Margin" Storyboard.TargetName="WPFToggleSwitchButton" Duration="0:0:0:0" From="0,0,0,0" To="28,0,0,0">
                                            </ThicknessAnimation>
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.ExitActions>
                                <Setter TargetName="WPFToggleSwitchButton" Property="Background" Value="#fff9f4f4" />
                            </Trigger>
                            <Trigger Property="IsChecked" Value="true">
                                <Trigger.ExitActions>
                                    <RemoveStoryboard BeginStoryboardName="WPFToggleSwitchRight" />
                                    <BeginStoryboard Name="WPFToggleSwitchLeft">
                                        <Storyboard>
                                            <ThicknessAnimation Storyboard.TargetProperty="Margin" Storyboard.TargetName="WPFToggleSwitchButton" Duration="0:0:0:0" From="28,0,0,0" To="0,0,0,0">
                                            </ThicknessAnimation>
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.ExitActions>
                                <Setter TargetName="WPFToggleSwitchButton" Property="Background" Value="#ff060600" />
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="ColorfulToggleSwitchStyle" TargetType="{x:Type CheckBox}">
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="{x:Type ToggleButton}">
                        <Grid Name="toggleSwitch">

                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="Auto" />
                            <ColumnDefinition Width="Auto" />
                        </Grid.ColumnDefinitions>

                        <Border Grid.Column="1" Name="Border" CornerRadius="8" BorderThickness="1" Width="34" Height="17">
                            <Ellipse Name="Ellipse" Fill="{DynamicResource MainForegroundColor}" Stretch="Uniform" Margin="2,2,2,1" HorizontalAlignment="Left" Width="10.8" RenderTransformOrigin="0.5, 0.5">
                                <Ellipse.RenderTransform>
                                    <ScaleTransform ScaleX="1" ScaleY="1" />
                                </Ellipse.RenderTransform>
                            </Ellipse>
                        </Border>
                        </Grid>

                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Border" Property="BorderBrush" Value="{DynamicResource MainForegroundColor}" />
                                <Setter TargetName="Border" Property="Background" Value="{DynamicResource LinkHoverForegroundColor}" />
                                <Setter Property="Cursor" Value="Hand" />
                                <Setter Property="Panel.ZIndex" Value="1000" />
                                <Trigger.EnterActions>
                                    <BeginStoryboard>
                                        <Storyboard>
                                            <DoubleAnimation Storyboard.TargetName="Ellipse" Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)" To="1.1" Duration="0:0:0.1" />
                                            <DoubleAnimation Storyboard.TargetName="Ellipse" Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)" To="1.1" Duration="0:0:0.1" />
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.EnterActions>
                                <Trigger.ExitActions>
                                    <BeginStoryboard>
                                        <Storyboard>
                                            <DoubleAnimation Storyboard.TargetName="Ellipse" Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)" To="1.0" Duration="0:0:0.1" />
                                            <DoubleAnimation Storyboard.TargetName="Ellipse" Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)" To="1.0" Duration="0:0:0.1" />
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.ExitActions>
                            </Trigger>
                            <Trigger Property="ToggleButton.IsChecked" Value="False">
                                <Setter TargetName="Border" Property="Background" Value="{DynamicResource MainBackgroundColor}" />
                                <Setter TargetName="Border" Property="BorderBrush" Value="{DynamicResource ToggleButtonOffColor}" />
                                <Setter TargetName="Ellipse" Property="Fill" Value="{DynamicResource ToggleButtonOffColor}" />
                            </Trigger>

                            <Trigger Property="ToggleButton.IsChecked" Value="True">
                                <Setter TargetName="Border" Property="Background" Value="{DynamicResource ToggleButtonOnColor}" />
                                <Setter TargetName="Border" Property="BorderBrush" Value="{DynamicResource ToggleButtonOnColor}" />
                                <Setter TargetName="Ellipse" Property="Fill" Value="White" />

                                <Trigger.EnterActions>
                                    <BeginStoryboard>
                                        <Storyboard>
                                            <ThicknessAnimation Storyboard.TargetName="Ellipse" Storyboard.TargetProperty="Margin" To="18,2,2,2" Duration="0:0:0.1" />
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.EnterActions>
                                <Trigger.ExitActions>
                                    <BeginStoryboard>
                                        <Storyboard>
                                            <ThicknessAnimation Storyboard.TargetName="Ellipse" Storyboard.TargetProperty="Margin" To="2,2,2,1" Duration="0:0:0.1" />
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.ExitActions>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Setter Property="VerticalContentAlignment" Value="Center" />
        </Style>


        <Style x:Key="BorderStyle" TargetType="Border">
            <Setter Property="Background" Value="{DynamicResource MainBackgroundColor}" />
            <Setter Property="BorderBrush" Value="{DynamicResource BorderColor}" />
            <Setter Property="BorderThickness" Value="1" />
            <Setter Property="CornerRadius" Value="5" />
            <Setter Property="Padding" Value="5" />
            <Setter Property="Margin" Value="5" />
            <Setter Property="Effect">
                <Setter.Value>
                    <DropShadowEffect ShadowDepth="5" BlurRadius="5" Opacity="{DynamicResource BorderOpacity}" Color="{DynamicResource CBorderColor}" />
                </Setter.Value>
            </Setter>
        </Style>

        <Style TargetType="TextBox">
            <Setter Property="Background" Value="{DynamicResource MainBackgroundColor}" />
            <Setter Property="BorderBrush" Value="{DynamicResource MainForegroundColor}" />
            <Setter Property="BorderThickness" Value="1" />
            <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}" />
            <Setter Property="FontSize" Value="{DynamicResource FontSize}" />
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}" />
            <Setter Property="Padding" Value="5" />
            <Setter Property="HorizontalAlignment" Value="Stretch" />
            <Setter Property="VerticalAlignment" Value="Center" />
            <Setter Property="HorizontalContentAlignment" Value="Stretch" />
            <Setter Property="CaretBrush" Value="{DynamicResource MainForegroundColor}" />
            <Setter Property="ContextMenu">
                <Setter.Value>
                    <ContextMenu>
                        <ContextMenu.Style>
                            <Style TargetType="ContextMenu">
                                <Setter Property="Template">
                                    <Setter.Value>
                                        <ControlTemplate TargetType="ContextMenu">
                                            <Border Background="{DynamicResource MainBackgroundColor}" BorderBrush="{DynamicResource BorderColor}" BorderThickness="1" CornerRadius="5" Padding="5">
                                                <StackPanel>
                                                    <MenuItem Command="Cut" Header="Cut" />
                                                    <MenuItem Command="Copy" Header="Copy" />
                                                    <MenuItem Command="Paste" Header="Paste" />
                                                </StackPanel>
                                            </Border>
                                        </ControlTemplate>
                                    </Setter.Value>
                                </Setter>
                            </Style>
                        </ContextMenu.Style>
                    </ContextMenu>
                </Setter.Value>
            </Setter>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="TextBox">
                        <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="5">
                                <ScrollViewer Name="PART_ContentHost" />
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Setter Property="Effect">
                <Setter.Value>
                    <DropShadowEffect ShadowDepth="5" BlurRadius="5" Opacity="{DynamicResource BorderOpacity}" Color="{DynamicResource CBorderColor}" />
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="PasswordBox">
            <Setter Property="Background" Value="{DynamicResource MainBackgroundColor}" />
            <Setter Property="BorderBrush" Value="{DynamicResource MainForegroundColor}" />
            <Setter Property="BorderThickness" Value="1" />
            <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}" />
            <Setter Property="FontSize" Value="{DynamicResource FontSize}" />
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}" />
            <Setter Property="Padding" Value="5" />
            <Setter Property="HorizontalAlignment" Value="Stretch" />
            <Setter Property="VerticalAlignment" Value="Center" />
            <Setter Property="HorizontalContentAlignment" Value="Stretch" />
            <Setter Property="CaretBrush" Value="{DynamicResource MainForegroundColor}" />
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="PasswordBox">
                        <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="5">
                                <ScrollViewer Name="PART_ContentHost" />
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Setter Property="Effect">
                <Setter.Value>
                    <DropShadowEffect ShadowDepth="5" BlurRadius="5" Opacity="{DynamicResource BorderOpacity}" Color="{DynamicResource CBorderColor}" />
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="RoundedProgressBarStyle" TargetType="ProgressBar">
            <!-- The fill follows Foreground so a run that ended badly can say so; the job layer
                 points it at the error or warning colour and back again -->
            <Setter Property="Foreground" Value="{DynamicResource ProgressBarForegroundColor}" />
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ProgressBar">
                        <Border CornerRadius="4" Background="{DynamicResource MainBackgroundColor}" BorderBrush="{DynamicResource MainForegroundColor}" BorderThickness="1">
                            <Grid ClipToBounds="True">
                                <Border Name="PART_Track" CornerRadius="4" Background="Transparent" />
                                <Border Name="PART_Indicator" CornerRadius="4" Background="{TemplateBinding Foreground}" HorizontalAlignment="Left" />
                            </Grid>
                        </Border>
                        <ControlTemplate.Triggers>
                            <!-- Work whose length cannot be measured, such as an installer that
                                 reports nothing until it exits. Pulsing says "still running"
                                 where a static bar would read as finished.

                                 Driven by Tag rather than IsIndeterminate: that property makes
                                 WPF ignore Value and stretch the indicator across the whole
                                 track, which would throw away the progress reached so far. -->
                            <Trigger Property="Tag" Value="Pulse">
                                <Trigger.EnterActions>
                                    <BeginStoryboard Name="IndeterminatePulse">
                                        <Storyboard>
                                            <DoubleAnimation Storyboard.TargetName="PART_Indicator" Storyboard.TargetProperty="Opacity" From="1.0" To="0.35" Duration="0:0:0.9" AutoReverse="True" RepeatBehavior="Forever" />
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.EnterActions>
                                <Trigger.ExitActions>
                                    <!-- Remove, not Stop: stopping leaves the indicator at
                                         whatever opacity the pulse was on -->
                                    <RemoveStoryboard BeginStoryboardName="IndeterminatePulse" />
                                </Trigger.ExitActions>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <!-- Filter Chip Style — used by the Install tab category filter buttons -->
        <Style x:Key="FilterChipStyle" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
            <Setter Property="Margin" Value="2" />
            <Setter Property="Padding" Value="12,0,12,0" />
            <Setter Property="Width" Value="Auto" />
            <Setter Property="Cursor" Value="Hand" />
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Name="ChipBorder" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{DynamicResource ButtonBorderThickness}" CornerRadius="{DynamicResource ButtonCornerRadius}" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" />
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="ChipBorder" Property="Background" Value="{DynamicResource ButtonBackgroundPressedColor}" />
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="ChipBorder" Property="Background" Value="{DynamicResource ButtonBackgroundMouseoverColor}" />
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="ChipBorder" Property="Background" Value="{DynamicResource ButtonBackgroundSelectedColor}" />
                                <Setter Property="Foreground" Value="DimGray" />
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <!-- Category filter chips. A toggle rather than a button, so the active filter is visible
             on the chip itself instead of only in the results below. -->
        <Style x:Key="FilterChipToggleStyle" TargetType="ToggleButton">
            <Setter Property="Margin" Value="2" />
            <Setter Property="Padding" Value="12,4,12,4" />
            <Setter Property="Cursor" Value="Hand" />
            <Setter Property="FontSize" Value="{DynamicResource ButtonFontSize}" />
            <Setter Property="FontFamily" Value="{DynamicResource ButtonFontFamily}" />
            <Setter Property="Foreground" Value="{DynamicResource ButtonForegroundColor}" />
            <Setter Property="Background" Value="{DynamicResource ButtonBackgroundColor}" />
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ToggleButton">
                        <Border Name="ChipBorder" Background="{TemplateBinding Background}" BorderBrush="{DynamicResource BorderColor}" BorderThickness="1" CornerRadius="{DynamicResource ButtonCornerRadius}" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" TextBlock.Foreground="{TemplateBinding Foreground}" TextBlock.FontSize="{TemplateBinding FontSize}" />
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="ChipBorder" Property="Background" Value="{DynamicResource ButtonBackgroundMouseoverColor}" />
                            </Trigger>
                            <!-- Only colours change on check. Anything affecting text width, bold for
                                 instance, would resize the chip and shift every chip after it. -->
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="ChipBorder" Property="Background" Value="{DynamicResource ButtonBackgroundSelectedColor}" />
                                <Setter TargetName="ChipBorder" Property="BorderBrush" Value="{DynamicResource LabelboxForegroundColor}" />
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <!-- Guided mode: large mode cards and the highlighted answer button -->
        <Style x:Key="GuidedCardButton" TargetType="Button">
            <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}" />
            <Setter Property="Background" Value="{DynamicResource ButtonBackgroundColor}" />
            <Setter Property="BorderBrush" Value="{DynamicResource BorderColor}" />
            <Setter Property="HorizontalContentAlignment" Value="Stretch" />
            <Setter Property="Cursor" Value="Hand" />
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Name="CardBorder" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="2" CornerRadius="8" Padding="24">
                            <ContentPresenter HorizontalAlignment="Stretch" VerticalAlignment="Top" />
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="CardBorder" Property="BorderBrush" Value="{DynamicResource ToggleButtonOnColor}" />
                            </Trigger>
                            <Trigger Property="IsKeyboardFocused" Value="True">
                                <Setter TargetName="CardBorder" Property="BorderBrush" Value="{DynamicResource ToggleButtonOnColor}" />
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="GuidedPrimaryButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
            <Setter Property="Background" Value="{DynamicResource ToggleButtonOnColor}" />
            <Setter Property="Foreground" Value="White" />
            <Setter Property="FontWeight" Value="Bold" />
        </Style>
    </Window.Resources>
    <Grid Background="{DynamicResource MainBackgroundColor}" ShowGridLines="False" Name="WPFMainGrid" Width="Auto" Height="Auto" HorizontalAlignment="Stretch">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto" />
            <RowDefinition Height="Auto" />
            <RowDefinition Height="*" />
            <RowDefinition Height="Auto" />
        </Grid.RowDefinitions>
        <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*" />
        </Grid.ColumnDefinitions>
        <!-- Offline banner -->
        <Border Name="WPFOfflineBanner" Grid.Row="0" Background="#8B0000" Visibility="Collapsed" Padding="6,4">
            <TextBlock Text="⚠ Offline Mode - No Internet Connection" Foreground="White" FontWeight="Bold" HorizontalAlignment="Center" FontSize="13" Background="Transparent" />
        </Border>
        <Grid Grid.Row="1" Background="{DynamicResource MainBackgroundColor}">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="Auto" /> <!-- Navigation buttons -->
                <ColumnDefinition Width="*" /> <!-- Search bar and buttons -->
            </Grid.ColumnDefinitions>

            <!-- Navigation Buttons Panel -->
            <StackPanel Name="NavDockPanel" Orientation="Horizontal" Grid.Column="0" VerticalAlignment="Center" Margin="5,5,10,5">
                <StackPanel Name="NavLogoPanel" Orientation="Horizontal" HorizontalAlignment="Left" Background="{DynamicResource MainBackgroundColor}" SnapsToDevicePixels="True" Margin="10,0,20,0">
                </StackPanel>

                <ToggleButton Style="{StaticResource TabToggleButton}" Margin="0,0,5,0" Height="{DynamicResource TabButtonHeight}" Width="{DynamicResource TabButtonWidth}" Background="{DynamicResource ButtonTweaksBackgroundColor}" Foreground="{DynamicResource ButtonTweaksForegroundColor}" FontWeight="Bold" Name="WPFTab2BT" IsChecked="True">
                    <ToggleButton.Content>
                        <TextBlock FontSize="{DynamicResource TabButtonFontSize}" Background="Transparent" Foreground="{DynamicResource ButtonTweaksForegroundColor}">
                            <Underline>T</Underline>weaks
                        </TextBlock>
                    </ToggleButton.Content>
                </ToggleButton>

                <ToggleButton Style="{StaticResource TabToggleButton}" Margin="0,0,5,0" Height="{DynamicResource TabButtonHeight}" Width="{DynamicResource TabButtonWidth}" Background="{DynamicResource ButtonTweaksBackgroundColor}" Foreground="{DynamicResource ButtonTweaksForegroundColor}" FontWeight="Bold" Name="WPFAdvancedTabBT" IsChecked="False">
                    <ToggleButton.Content>
                        <TextBlock FontSize="{DynamicResource TabButtonFontSize}" Background="Transparent" Foreground="{DynamicResource ButtonTweaksForegroundColor}"><Underline>A</Underline>dvanced</TextBlock>
                    </ToggleButton.Content>
                </ToggleButton>




            </StackPanel>

            <!-- Search Bar and Action Buttons -->
            <Grid Name="GridBesideNavDockPanel" Grid.Column="1" Background="{DynamicResource MainBackgroundColor}" ShowGridLines="False" Height="Auto">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="2*" /> <!-- Search bar area - priority space -->
                    <ColumnDefinition Width="Auto" /><!-- Buttons area -->
                </Grid.ColumnDefinitions>

                <Border Name="WPFSearchBarContainer" Grid.Column="0" Margin="5,0,10,0" MinWidth="120" Height="{DynamicResource SearchBarHeight}" VerticalAlignment="Center" HorizontalAlignment="Stretch">
                    <Grid>
                        <TextBox Height="{DynamicResource SearchBarHeight}" FontSize="{DynamicResource SearchBarTextBoxFontSize}" VerticalAlignment="Center" HorizontalAlignment="Stretch" BorderThickness="1" Name="SearchBar" Foreground="{DynamicResource MainForegroundColor}" Background="{DynamicResource MainBackgroundColor}" Padding="3,3,30,0" ToolTip="Buscar ajustes de Windows. Ctrl+F para buscar; Esc para limpiar." AutomationProperties.Name="Search">
                        </TextBox>
                        <TextBlock Name="SearchBarIcon" VerticalAlignment="Center" HorizontalAlignment="Right" FontFamily="Segoe MDL2 Assets" Foreground="{DynamicResource ButtonBackgroundSelectedColor}" FontSize="{DynamicResource IconFontSize}" Margin="0,0,8,0" Width="Auto" Height="Auto">
                        </TextBlock>
                    </Grid>
                </Border>
                <Button Grid.Column="0" VerticalAlignment="Center" HorizontalAlignment="Right" Name="SearchBarClearButton" Style="{StaticResource SearchBarClearButtonStyle}" AutomationProperties.Name="Clear Search" Margin="0,0,20,0" Visibility="Collapsed">
                </Button>

                <!-- Buttons Container -->
                <StackPanel Grid.Column="1" Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="5,5,5,5">
                    <Button Name="ThemeButton" Style="{StaticResource HoverButtonStyle}" BorderBrush="Transparent" Background="{DynamicResource MainBackgroundColor}" Foreground="{DynamicResource MainForegroundColor}" FontSize="{DynamicResource SettingsIconFontSize}" Width="{DynamicResource IconButtonSize}" Height="{DynamicResource IconButtonSize}" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,2,0" FontFamily="Segoe MDL2 Assets" Content="N/A" ToolTip="Change the APBOptimizer theme" AutomationProperties.Name="Theme" />
                    <Popup Name="ThemePopup" IsOpen="False" PlacementTarget="{Binding ElementName=ThemeButton}" Placement="Bottom" HorizontalAlignment="Right" VerticalAlignment="Top">
                    <Border Background="{DynamicResource MainBackgroundColor}" BorderBrush="{DynamicResource MainForegroundColor}" BorderThickness="1" CornerRadius="0" Margin="0">
                        <StackPanel Background="{DynamicResource MainBackgroundColor}" HorizontalAlignment="Stretch" VerticalAlignment="Stretch">
                            <MenuItem FontSize="{DynamicResource ButtonFontSize}" Header="Auto" Name="AutoThemeMenuItem" Foreground="{DynamicResource MainForegroundColor}">
                                <MenuItem.ToolTip>
                                    <ToolTip Content="Follow the Windows Theme" />
                                </MenuItem.ToolTip>
                            </MenuItem>
                            <MenuItem FontSize="{DynamicResource ButtonFontSize}" Header="Dark" Name="DarkThemeMenuItem" Foreground="{DynamicResource MainForegroundColor}">
                                <MenuItem.ToolTip>
                                    <ToolTip Content="Use Dark Theme" />
                                </MenuItem.ToolTip>
                            </MenuItem>
                            <MenuItem FontSize="{DynamicResource ButtonFontSize}" Header="Light" Name="LightThemeMenuItem" Foreground="{DynamicResource MainForegroundColor}">
                                <MenuItem.ToolTip>
                                    <ToolTip Content="Use Light Theme" />
                                </MenuItem.ToolTip>
                            </MenuItem>
                        </StackPanel>
                    </Border>
                </Popup>

                    <Button Name="FontScalingButton" Style="{StaticResource HoverButtonStyle}" BorderBrush="Transparent" Background="{DynamicResource MainBackgroundColor}" Foreground="{DynamicResource MainForegroundColor}" FontSize="{DynamicResource SettingsIconFontSize}" Width="{DynamicResource IconButtonSize}" Height="{DynamicResource IconButtonSize}" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,2,0" FontFamily="Segoe MDL2 Assets" Content="" ToolTip="Adjust Font Scaling for Accessibility" AutomationProperties.Name="Font Scaling" />
                    <Popup Name="FontScalingPopup" IsOpen="False" PlacementTarget="{Binding ElementName=FontScalingButton}" Placement="Bottom" HorizontalAlignment="Right" VerticalAlignment="Top">
                    <Border Background="{DynamicResource MainBackgroundColor}" BorderBrush="{DynamicResource MainForegroundColor}" BorderThickness="1" CornerRadius="0" Margin="0">
                        <StackPanel Background="{DynamicResource MainBackgroundColor}" HorizontalAlignment="Stretch" VerticalAlignment="Stretch" MinWidth="200">
                            <TextBlock Name="WPFFontScalingTitle" Text="Font Scaling" FontSize="{DynamicResource ButtonFontSize}" Foreground="{DynamicResource MainForegroundColor}" HorizontalAlignment="Center" Margin="10,5,10,5" FontWeight="Bold" />
                            <Separator Margin="5,0,5,5" />
                            <StackPanel Orientation="Horizontal" Margin="10,5,10,10">
                                <TextBlock Name="WPFFontSmall" Text="Small" FontSize="{DynamicResource ButtonFontSize}" Foreground="{DynamicResource MainForegroundColor}" VerticalAlignment="Center" Margin="0,0,10,0" />
                                <Slider Name="FontScalingSlider" Minimum="0.75" Maximum="2.0" Value="1.0" TickFrequency="0.25" TickPlacement="BottomRight" IsSnapToTickEnabled="True" IsMoveToPointEnabled="True" SmallChange="0.25" LargeChange="0.25" Width="120" VerticalAlignment="Center" AutomationProperties.Name="Font Scaling" />
                                <TextBlock Name="WPFFontLarge" Text="Large" FontSize="{DynamicResource ButtonFontSize}" Foreground="{DynamicResource MainForegroundColor}" VerticalAlignment="Center" Margin="10,0,0,0" />
                            </StackPanel>
                            <TextBlock Name="FontScalingValue" Text="100%" FontSize="{DynamicResource ButtonFontSize}" Foreground="{DynamicResource MainForegroundColor}" HorizontalAlignment="Center" Margin="10,0,10,5" />
                            <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" Margin="10,0,10,10">
                                <Button Name="FontScalingResetButton" Content="Reset" Style="{StaticResource HoverButtonStyle}" Width="60" Height="25" Margin="5,0,5,0" />
                                <Button Name="FontScalingApplyButton" Content="Apply" Style="{StaticResource HoverButtonStyle}" Width="60" Height="25" Margin="5,0,5,0" />
                            </StackPanel>
                        </StackPanel>
                    </Border>
                </Popup>

                    <Button Name="SettingsButton" Style="{StaticResource HoverButtonStyle}" BorderBrush="Transparent" Background="{DynamicResource MainBackgroundColor}" Foreground="{DynamicResource MainForegroundColor}" FontSize="{DynamicResource SettingsIconFontSize}" Width="{DynamicResource IconButtonSize}" Height="{DynamicResource IconButtonSize}" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,2,0" FontFamily="Segoe MDL2 Assets" ToolTip="Settings" AutomationProperties.Name="Settings" Content="" />
                    <Popup Name="SettingsPopup" IsOpen="False" PlacementTarget="{Binding ElementName=SettingsButton}" Placement="Bottom" HorizontalAlignment="Right" VerticalAlignment="Top">
                    <Border Background="{DynamicResource MainBackgroundColor}" BorderBrush="{DynamicResource MainForegroundColor}" BorderThickness="1" CornerRadius="0" Margin="0">
                        <StackPanel Background="{DynamicResource MainBackgroundColor}" HorizontalAlignment="Stretch" VerticalAlignment="Stretch">
                            <MenuItem FontSize="{DynamicResource ButtonFontSize}" Header="Import" Name="ImportMenuItem" Foreground="{DynamicResource MainForegroundColor}">
                                <MenuItem.ToolTip>
                                    <ToolTip Content="Import Configuration from exported file." />
                                </MenuItem.ToolTip>
                            </MenuItem>
                            <MenuItem FontSize="{DynamicResource ButtonFontSize}" Header="Export" Name="ExportMenuItem" Foreground="{DynamicResource MainForegroundColor}">
                                <MenuItem.ToolTip>
                                    <ToolTip Content="Export Selected Elements and copy execution command to clipboard." />
                                </MenuItem.ToolTip>
                            </MenuItem>
                            <MenuItem FontSize="{DynamicResource ButtonFontSize}" Header="Guided mode" Name="GuidedModeMenuItem" Foreground="{DynamicResource MainForegroundColor}">
                                <MenuItem.ToolTip>
                                    <ToolTip Content="Open the guided mode window: one question at a time, then a summary." />
                                </MenuItem.ToolTip>
                            </MenuItem>
                            <Separator />
                            <TextBlock Name="WPFLanguageLabel" Text="Language" Foreground="{DynamicResource MainForegroundColor}" FontSize="{DynamicResource ButtonFontSize}" Margin="10,6,10,4" />
                            <ComboBox Name="WPFLanguageSelector" MinWidth="180" Margin="8,0,8,8" FontSize="{DynamicResource ButtonFontSize}" ToolTip="Choose the interface language (automatic follows Windows)">
                                <ComboBoxItem Content="Automatic (Windows)" Tag="auto" />
                                <ComboBoxItem Content="Español" Tag="es" />
                                <ComboBoxItem Content="English" Tag="en" />
                            </ComboBox>
                            <Separator />
                            <MenuItem FontSize="{DynamicResource ButtonFontSize}" Header="About" Name="AboutMenuItem" Foreground="{DynamicResource MainForegroundColor}" />


                        </StackPanel>
                    </Border>
                </Popup>

                    <Button Content="" Style="{StaticResource HoverButtonStyle}" BorderThickness="0" BorderBrush="Transparent" Background="{DynamicResource MainBackgroundColor}" Width="{DynamicResource IconButtonSize}" Height="{DynamicResource IconButtonSize}" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0" FontFamily="Segoe MDL2 Assets" Foreground="{DynamicResource MainForegroundColor}" FontSize="{DynamicResource CloseIconFontSize}" ToolTip="Minimize" AutomationProperties.Name="Minimize" Name="WPFMinimizeButton" />
                    <Button BorderThickness="0" BorderBrush="Transparent" Background="{DynamicResource MainBackgroundColor}" Width="{DynamicResource IconButtonSize}" Height="{DynamicResource IconButtonSize}" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,0,0" FontFamily="Segoe MDL2 Assets" Foreground="{DynamicResource MainForegroundColor}" FontSize="{DynamicResource CloseIconFontSize}" Name="WPFMaximizeButton">
                        <Button.Style>
                            <Style TargetType="Button" BasedOn="{StaticResource HoverButtonStyle}">
                                <Setter Property="Content" Value="" />
                                <Setter Property="ToolTip" Value="Maximize" />
                                <Setter Property="AutomationProperties.Name" Value="Maximize" />
                                <Style.Triggers>
                                    <DataTrigger Binding="{Binding WindowState, RelativeSource={RelativeSource AncestorType={x:Type Window}}}" Value="Maximized">
                                        <Setter Property="Content" Value="" />
                                        <Setter Property="ToolTip" Value="Restore" />
                                        <Setter Property="AutomationProperties.Name" Value="Restore" />
                                    </DataTrigger>
                                </Style.Triggers>
                            </Style>
                        </Button.Style>
                    </Button>

                    <Button Content="" Style="{StaticResource HoverButtonStyle}" BorderThickness="0" BorderBrush="Transparent" Background="{DynamicResource MainBackgroundColor}" Width="{DynamicResource IconButtonSize}" Height="{DynamicResource IconButtonSize}" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0" FontFamily="Segoe MDL2 Assets" Foreground="{DynamicResource MainForegroundColor}" FontSize="{DynamicResource CloseIconFontSize}" ToolTip="Close" AutomationProperties.Name="Close" Name="WPFCloseButton" />
                </StackPanel>
            </Grid>
        </Grid>

        <TabControl Name="WPFTabNav" Background="Transparent" Width="Auto" Height="Auto" BorderBrush="Transparent" BorderThickness="0" Grid.Row="2" Grid.Column="0" Padding="-1">

            <TabItem Header="Tweaks" Visibility="Collapsed" Name="WPFTab2">
                <Grid>
                    <!-- Main content area with a ScrollViewer -->
                    <Grid.RowDefinitions>
                        <RowDefinition Height="*" />
                        <RowDefinition Height="Auto" />
                    </Grid.RowDefinitions>

                    <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Grid.Row="0" Margin="{DynamicResource TabContentMargin}">
                        <Grid Background="Transparent">
                            <Grid.RowDefinitions>
                                <RowDefinition Height="Auto" />
                                <RowDefinition Height="*" />
                                <RowDefinition Height="Auto" />
                            </Grid.RowDefinitions>

                            <StackPanel Background="{DynamicResource MainBackgroundColor}" Orientation="Vertical" Grid.Row="0" Grid.Column="0" Grid.ColumnSpan="2" Margin="5">
                                <Label Name="WPFRecommendedLabel" Content="Recommended Selections:" FontSize="{DynamicResource FontSize}" VerticalAlignment="Center" Margin="2" />
                                <WrapPanel Orientation="Horizontal" HorizontalAlignment="Left" Margin="0,2,0,0">
                                    <Button Name="WPFstandard" Content=" Standard " Margin="2" Width="{DynamicResource ButtonWidth}" Height="{DynamicResource ButtonHeight}" />
                                    <Button Name="WPFminimal" Content=" Minimal " Margin="2" Width="{DynamicResource ButtonWidth}" Height="{DynamicResource ButtonHeight}" />
                                    <Button Name="WPFAdvanced" Content=" Advanced " Margin="2" Width="{DynamicResource ButtonWidth}" Height="{DynamicResource ButtonHeight}" />
                                    <Button Name="WPFClearTweaksSelection" Content=" Clear " Margin="2" Width="{DynamicResource ButtonWidth}" Height="{DynamicResource ButtonHeight}" />
                                    <Button Name="WPFGetInstalledTweaks" Content=" Select Installed Tweaks " Margin="2" Width="{DynamicResource ButtonWidth}" Height="{DynamicResource ButtonHeight}" />

                                </WrapPanel>
                            </StackPanel>

                            <Grid Name="tweakspanel" Grid.Row="1">
                                <!-- Your tweakspanel content goes here -->
                            </Grid>

                            <Border Grid.ColumnSpan="2" Grid.Row="2" Grid.Column="0" Style="{StaticResource BorderStyle}">
                                <StackPanel Background="{DynamicResource MainBackgroundColor}" Orientation="Horizontal" HorizontalAlignment="Left">
                                    <TextBlock Name="WPFInfoNote" Padding="10" TextWrapping="Wrap" Text="Note: Hover over items to get a better description. Some tweaks heavily modify Windows. Recommended selections are for normal users; if you are unsure, do not select anything else." />
                                </StackPanel>
                            </Border>
                        </Grid>
                    </ScrollViewer>
                    <Border Grid.Row="1" Background="{DynamicResource MainBackgroundColor}" BorderBrush="{DynamicResource BorderColor}" BorderThickness="1" CornerRadius="5" HorizontalAlignment="Stretch" Padding="10">
                        <WrapPanel Orientation="Horizontal" HorizontalAlignment="Left" VerticalAlignment="Center" Grid.Column="0">
                            <Button Name="WPFTweaksbutton" Content="Run Tweaks" Margin="5" Width="{DynamicResource ButtonWidth}" Height="{DynamicResource ButtonHeight}" />
                            <Button Name="WPFUndoall" Content="Undo Selected Tweaks" Margin="5" Width="{DynamicResource ButtonWidth}" Height="{DynamicResource ButtonHeight}" />
                        </WrapPanel>
                    </Border>
                </Grid>
            </TabItem>

            <TabItem Header="Advanced" Visibility="Collapsed" Name="WPFAdvancedTab">
                <Grid Background="{DynamicResource MainBackgroundColor}">
                    <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                        <StackPanel MaxWidth="760" Margin="24,42" HorizontalAlignment="Center">
                            <TextBlock Name="WPFAdvancedHeading" Text="Advanced" FontSize="30" FontWeight="Bold" Foreground="{DynamicResource MainForegroundColor}" TextAlignment="Center" Margin="0,0,0,20" />
                            <Border Background="{DynamicResource MainBackgroundColor}" BorderBrush="{DynamicResource BorderColor}" BorderThickness="1" CornerRadius="6" Padding="20">
                                <StackPanel>
                                    <TextBlock Name="WPFWindowsUpdateHeading" Text="Windows Update" FontSize="20" FontWeight="Bold" Foreground="{DynamicResource MainForegroundColor}" Margin="0,0,0,8" />
                                    <TextBlock Name="WPFWindowsUpdateDescription" Text="Aggressive mode: disables update services and attempts to rename protected Windows Update DLLs. Updates and Windows repair may stop working. Restore uses saved file permissions and original settings. Requires administrator privileges." TextWrapping="Wrap" Foreground="{DynamicResource MainForegroundColor}" Margin="0,0,0,12" />
                                    <TextBlock Name="WPFWindowsUpdateStatus" Text="Windows Update status will appear here." TextWrapping="Wrap" FontWeight="SemiBold" Foreground="{DynamicResource MainForegroundColor}" Margin="0,0,0,16" />
                                    <WrapPanel>
                                        <Button Name="WPFDisableWindowsUpdate" Content="Disable Windows Update" MinWidth="190" Height="36" Margin="0,0,10,8" Padding="12,4" />
                                        <Button Name="WPFRestoreWindowsUpdate" Content="Restore Windows Update" IsEnabled="False" MinWidth="190" Height="36" Margin="0,0,0,8" Padding="12,4" />
                                    </WrapPanel>
                                </StackPanel>
                            </Border>
                        </StackPanel>
                    </ScrollViewer>
                </Grid>
            </TabItem>

        </TabControl>


        <!-- Window-level progress indicator - visible regardless of active tab -->
        <Border Name="WPFTweaksProgressBar" Grid.Row="3" Background="{DynamicResource MainBackgroundColor}" Visibility="Collapsed" Padding="10,6">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*" />
                </Grid.ColumnDefinitions>
                <StackPanel Grid.Column="0" Orientation="Vertical">
                    <TextBlock Name="WPFTweaksProgressLabel" Text="" Foreground="{DynamicResource MainForegroundColor}" FontSize="13" Background="Transparent" Margin="0,0,0,4" />
                    <ProgressBar Name="WPFTweaksProgressValue" Height="6" Minimum="0" Maximum="100" Value="0" Style="{StaticResource RoundedProgressBarStyle}" />
                </StackPanel>
            </Grid>
        </Border>

        <!-- Local, read-only help for the (?) icons. No scripts are executed here. -->
        <Popup Name="WPFTweakHelpPopup" Grid.Row="2" IsOpen="False"
               Placement="Center" HorizontalOffset="0" VerticalOffset="0" StaysOpen="False"
               AllowsTransparency="False" PopupAnimation="None">
            <!-- Opaque popup avoids layered-window alpha/effect artifacts on older GPUs.
                 The offset dark frame provides depth without shadowing the text itself. -->
            <Border Background="{DynamicResource TweakHelpShadowColor}" Padding="0,0,5,5">
                <Border Name="WPFTweakHelpCard" Width="520" MaxHeight="540" CornerRadius="8"
                        BorderThickness="2" BorderBrush="{DynamicResource TweakHelpBorderColor}"
                        Background="{DynamicResource TweakHelpBackgroundColor}">
                    <DockPanel LastChildFill="True">
                        <Border DockPanel.Dock="Top" Background="{DynamicResource TweakHelpHeaderColor}"
                                Padding="18,14" CornerRadius="6,6,0,0">
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*" />
                                    <ColumnDefinition Width="Auto" />
                                </Grid.ColumnDefinitions>
                                <TextBlock Name="WPFTweakHelpTitle" FontSize="19" FontWeight="SemiBold"
                                           Background="Transparent"
                                           FontFamily="Segoe UI" Foreground="{DynamicResource MainForegroundColor}"
                                           TextWrapping="Wrap" VerticalAlignment="Center" Margin="0,0,14,0" />
                                <Button Grid.Column="1" Name="WPFTweakHelpClose" Content="×"
                                        Width="32" Height="32" FontSize="17" ToolTip="Close"
                                        Background="{DynamicResource TweakHelpSectionColor}"
                                        Foreground="{DynamicResource MainForegroundColor}"
                                        BorderBrush="{DynamicResource TweakHelpBorderColor}"
                                        BorderThickness="1" />
                            </Grid>
                        </Border>

                        <Border DockPanel.Dock="Bottom" Background="{DynamicResource TweakHelpHeaderColor}"
                                Padding="14,11" CornerRadius="0,0,6,6">
                            <Button Name="WPFTweakHelpDocs" Content="Original documentation"
                                    HorizontalAlignment="Right" MinWidth="165" Padding="14,8"
                                    Background="{DynamicResource TweakHelpSectionColor}"
                                    Foreground="{DynamicResource MainForegroundColor}"
                                    BorderBrush="{DynamicResource TweakHelpBorderColor}" BorderThickness="1"
                                    ToolTip="Opens the original Chris Titus Tech documentation" />
                        </Border>

                        <ScrollViewer MaxHeight="385" VerticalScrollBarVisibility="Auto"
                                      HorizontalScrollBarVisibility="Disabled" CanContentScroll="False">
                            <StackPanel Margin="16,14,20,14">
                                <Border Background="{DynamicResource TweakHelpSectionColor}" CornerRadius="5"
                                        Padding="12" Margin="0,0,0,12">
                                    <StackPanel>
                                        <TextBlock Name="WPFTweakHelpSummaryHeader" Text="What it does"
                                                   Background="Transparent"
                                                   Foreground="{DynamicResource MainForegroundColor}"
                                                   FontFamily="Segoe UI" FontSize="13" FontWeight="Bold"
                                                   Margin="0,0,0,8" />
                                        <TextBlock Name="WPFTweakHelpSummary" TextWrapping="Wrap"
                                                   Background="Transparent"
                                                   FontFamily="Segoe UI" FontSize="13" LineHeight="19"
                                                   Foreground="{DynamicResource MainForegroundColor}" />
                                    </StackPanel>
                                </Border>
                                <Border Background="{DynamicResource TweakHelpSectionColor}" CornerRadius="5"
                                        Padding="12" Margin="0,0,0,12">
                                    <StackPanel>
                                        <TextBlock Name="WPFTweakHelpChangesHeader" Text="How it works"
                                                   Background="Transparent"
                                                   Foreground="{DynamicResource MainForegroundColor}"
                                                   FontFamily="Segoe UI" FontSize="13" FontWeight="Bold"
                                                   Margin="0,0,0,8" />
                                        <TextBlock Name="WPFTweakHelpChanges" TextWrapping="Wrap"
                                                   Background="Transparent"
                                                   FontFamily="Consolas" FontSize="12" LineHeight="18"
                                                   Foreground="{DynamicResource MainForegroundColor}" />
                                    </StackPanel>
                                </Border>
                                <Border Background="{DynamicResource TweakHelpSectionColor}" CornerRadius="5"
                                        Padding="12">
                                    <StackPanel>
                                        <TextBlock Name="WPFTweakHelpUndoHeader" Text="How to undo it"
                                                   Background="Transparent"
                                                   Foreground="{DynamicResource MainForegroundColor}"
                                                   FontFamily="Segoe UI" FontSize="13" FontWeight="Bold"
                                                   Margin="0,0,0,8" />
                                        <TextBlock Name="WPFTweakHelpUndo" TextWrapping="Wrap"
                                                   Background="Transparent"
                                                   FontFamily="Segoe UI" FontSize="12.5" LineHeight="19"
                                                   Foreground="{DynamicResource MainForegroundColor}" />
                                    </StackPanel>
                                </Border>
                            </StackPanel>
                        </ScrollViewer>
                    </DockPanel>
                </Border>
            </Border>
        </Popup>
    </Grid>
</Window>

'@
$guidedXML = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" WindowStartupLocation="CenterScreen" UseLayoutRounding="True" WindowStyle="SingleBorderWindow" Width="1060" Height="720" MinWidth="860" MinHeight="600" Title="APBOptimizer" Background="{DynamicResource MainBackgroundColor}">
    <!-- Separate guided-mode window. Styles and theme colours come from the main window's
         resources, merged in at runtime, so every style here is a DynamicResource. -->
    <WindowChrome.WindowChrome>
        <WindowChrome CaptionHeight="0" CornerRadius="10" UseAeroCaptionButtons="False" />
    </WindowChrome.WindowChrome>
    <Grid Name="WPFGuidedRoot" Background="{DynamicResource MainBackgroundColor}">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto" />
            <RowDefinition Height="*" />
        </Grid.RowDefinitions>

        <DockPanel Name="WPFGuidedTitleBar" Grid.Row="0" Height="46" Background="{DynamicResource MainBackgroundColor}" LastChildFill="True">
            <StackPanel Name="GuidedLogoPanel" Orientation="Horizontal" DockPanel.Dock="Left" Margin="14,0,10,0" VerticalAlignment="Center" />
            <Button Name="WPFGuidedCloseWindow" DockPanel.Dock="Right" Style="{DynamicResource HoverButtonStyle}" BorderThickness="0" BorderBrush="Transparent" Background="{DynamicResource MainBackgroundColor}" Foreground="{DynamicResource MainForegroundColor}" Width="{DynamicResource IconButtonSize}" Height="{DynamicResource IconButtonSize}" Margin="0,0,6,0" FontFamily="Segoe MDL2 Assets" FontSize="{DynamicResource CloseIconFontSize}" Content="&#xE8BB;" ToolTip="Cerrar" AutomationProperties.Name="Cerrar" />
            <Button Name="WPFGuidedMinimizeWindow" DockPanel.Dock="Right" Style="{DynamicResource HoverButtonStyle}" BorderThickness="0" BorderBrush="Transparent" Background="{DynamicResource MainBackgroundColor}" Foreground="{DynamicResource MainForegroundColor}" Width="{DynamicResource IconButtonSize}" Height="{DynamicResource IconButtonSize}" Margin="0" FontFamily="Segoe MDL2 Assets" FontSize="{DynamicResource CloseIconFontSize}" Content="&#xE921;" ToolTip="Minimizar" AutomationProperties.Name="Minimizar" />
            <TextBlock Name="WPFGuidedWindowTitle" Text="APBOptimizer" VerticalAlignment="Center" FontFamily="Consolas, Monaco" FontSize="15" FontWeight="Bold" Foreground="{DynamicResource MainForegroundColor}" Background="Transparent" />
        </DockPanel>

        <Grid Grid.Row="1">
            <ScrollViewer Name="WPFModeChooser" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Visibility="Collapsed">
                <StackPanel MaxWidth="860" Margin="32,24,32,36" HorizontalAlignment="Center" VerticalAlignment="Center">
                    <TextBlock Name="WPFModeChooserTitle" Text="¿Cómo quieres optimizar Windows?" FontSize="28" FontWeight="Bold" TextAlignment="Center" TextWrapping="Wrap" Foreground="{DynamicResource MainForegroundColor}" Background="Transparent" />
                    <TextBlock Name="WPFModeChooserSubtitle" Text="El modo guiado te hace una pregunta a la vez. El modo avanzado abre la interfaz completa de APBOptimizer." FontSize="14" TextAlignment="Center" TextWrapping="Wrap" Foreground="{DynamicResource MainForegroundColor}" Background="Transparent" Opacity="0.8" Margin="0,8,0,24" />
                    <UniformGrid Columns="2">
                        <Button Name="WPFModeGuided" Style="{DynamicResource GuidedCardButton}" Margin="0,0,10,0" AutomationProperties.Name="Modo guiado">
                            <StackPanel>
                                <Border HorizontalAlignment="Left" Background="{DynamicResource ToggleButtonOnColor}" CornerRadius="10" Padding="10,3">
                                    <TextBlock Name="WPFModeGuidedBadge" Text="Recomendado" FontSize="12" FontWeight="Bold" Foreground="White" Background="Transparent" />
                                </Border>
                                <TextBlock Name="WPFModeGuidedTitle" Text="Modo guiado" FontSize="22" FontWeight="Bold" Foreground="{DynamicResource MainForegroundColor}" Background="Transparent" Margin="0,14,0,8" />
                                <TextBlock Name="WPFModeGuidedText" Text="Una pregunta por pantalla, con una explicación de qué cambia. Ves un resumen antes de aplicar nada." FontSize="14" TextWrapping="Wrap" Foreground="{DynamicResource MainForegroundColor}" Background="Transparent" />
                                <TextBlock Name="WPFModeGuidedMeta" Text="Unos 3 minutos" FontSize="13" Foreground="{DynamicResource MainForegroundColor}" Background="Transparent" Opacity="0.75" Margin="0,12,0,0" />
                            </StackPanel>
                        </Button>
                        <Button Name="WPFModeAdvanced" Style="{DynamicResource GuidedCardButton}" Margin="10,0,0,0" AutomationProperties.Name="Modo avanzado">
                            <StackPanel>
                                <Border HorizontalAlignment="Left" Background="Transparent" Padding="0,3">
                                    <TextBlock Text=" " FontSize="12" Background="Transparent" />
                                </Border>
                                <TextBlock Name="WPFModeAdvancedTitle" Text="Modo avanzado" FontSize="22" FontWeight="Bold" Foreground="{DynamicResource MainForegroundColor}" Background="Transparent" Margin="0,14,0,8" />
                                <TextBlock Name="WPFModeAdvancedText" Text="Abre la interfaz completa con todos los ajustes, servicios, drivers y opciones de Windows Update." FontSize="14" TextWrapping="Wrap" Foreground="{DynamicResource MainForegroundColor}" Background="Transparent" />
                                <TextBlock Name="WPFModeAdvancedMeta" Text="Para quienes saben qué tocar" FontSize="13" Foreground="{DynamicResource MainForegroundColor}" Background="Transparent" Opacity="0.75" Margin="0,12,0,0" />
                            </StackPanel>
                        </Button>
                    </UniformGrid>
                </StackPanel>
            </ScrollViewer>

            <Grid Name="WPFGuidedWizard" Margin="40,10,40,16" Visibility="Collapsed">
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto" />
                    <RowDefinition Height="*" />
                    <RowDefinition Height="Auto" />
                </Grid.RowDefinitions>
                <StackPanel Grid.Row="0">
                    <DockPanel>
                        <TextBlock Name="WPFGuidedStep" DockPanel.Dock="Right" FontSize="13" Foreground="{DynamicResource MainForegroundColor}" Background="Transparent" Opacity="0.8" />
                        <TextBlock Name="WPFGuidedCategory" FontSize="13" Foreground="{DynamicResource MainForegroundColor}" Background="Transparent" Opacity="0.8" />
                    </DockPanel>
                    <ProgressBar Name="WPFGuidedProgress" Height="8" Minimum="0" Maximum="100" Value="0" Margin="0,8,0,0" Style="{DynamicResource RoundedProgressBarStyle}" Foreground="{DynamicResource ToggleButtonOnColor}" />
                </StackPanel>
                <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Margin="0,22,0,12">
                    <StackPanel MaxWidth="820" HorizontalAlignment="Left">
                        <WrapPanel Name="WPFGuidedBadges" />
                        <TextBlock Name="WPFGuidedTitle" FontSize="28" FontWeight="Bold" TextWrapping="Wrap" Foreground="{DynamicResource MainForegroundColor}" Background="Transparent" Margin="0,12,0,0" />
                        <TextBlock Name="WPFGuidedBody" FontSize="15" TextWrapping="Wrap" Foreground="{DynamicResource MainForegroundColor}" Background="Transparent" Opacity="0.9" Margin="0,12,0,0" LineHeight="22" />
                        <StackPanel Name="WPFGuidedDetails" Margin="0,16,0,0" Visibility="Collapsed">
                            <TextBlock Name="WPFGuidedDetailsTitle" Text="Qué cambia" FontSize="14" FontWeight="Bold" Foreground="{DynamicResource MainForegroundColor}" Background="Transparent" Margin="0,0,0,6" />
                            <StackPanel Name="WPFGuidedDetailsList" />
                        </StackPanel>
                        <Border Name="WPFGuidedNote" Background="{DynamicResource TweakHelpSectionColor}" BorderBrush="{DynamicResource TweakHelpBorderColor}" BorderThickness="1" CornerRadius="6" Padding="14,12" Margin="0,16,0,0" Visibility="Collapsed">
                            <TextBlock Name="WPFGuidedNoteText" FontSize="14" TextWrapping="Wrap" Foreground="{DynamicResource MainForegroundColor}" Background="Transparent" />
                        </Border>
                        <Border Name="WPFGuidedAdvice" BorderThickness="1.5" CornerRadius="6" Padding="14,12" Margin="0,16,0,0" Visibility="Collapsed">
                            <StackPanel>
                                <TextBlock Name="WPFGuidedAdviceTitle" FontSize="14" FontWeight="Bold" TextWrapping="Wrap" Foreground="{DynamicResource MainForegroundColor}" Background="Transparent" />
                                <TextBlock Name="WPFGuidedAdviceText" FontSize="14" TextWrapping="Wrap" Foreground="{DynamicResource MainForegroundColor}" Background="Transparent" Opacity="0.9" Margin="0,4,0,0" />
                            </StackPanel>
                        </Border>
                        <TextBlock Name="WPFGuidedState" FontSize="14" FontWeight="SemiBold" TextWrapping="Wrap" Foreground="{DynamicResource MainForegroundColor}" Background="Transparent" Margin="0,14,0,0" Visibility="Collapsed" />
                        <StackPanel Name="WPFGuidedOptions" Margin="0,16,0,0" />
                    </StackPanel>
                </ScrollViewer>
                <DockPanel Grid.Row="2" LastChildFill="False">
                    <Button Name="WPFGuidedBack" DockPanel.Dock="Left" Content="Atrás" Width="Auto" MinWidth="150" Height="40" FontSize="15" Margin="0" />
                    <Button Name="WPFGuidedYes" DockPanel.Dock="Right" Content="Sí" Width="Auto" MinWidth="150" Height="40" FontSize="15" Margin="10,0,0,0" />
                    <Button Name="WPFGuidedNo" DockPanel.Dock="Right" Content="No" Width="Auto" MinWidth="150" Height="40" FontSize="15" Margin="0" />
                </DockPanel>
            </Grid>

            <Grid Name="WPFGuidedSummary" Margin="40,10,40,16" Visibility="Collapsed">
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto" />
                    <RowDefinition Height="*" />
                    <RowDefinition Height="Auto" />
                    <RowDefinition Height="Auto" />
                </Grid.RowDefinitions>
                <StackPanel Grid.Row="0">
                    <TextBlock Name="WPFGuidedSummaryTitle" FontSize="26" FontWeight="Bold" TextWrapping="Wrap" Foreground="{DynamicResource MainForegroundColor}" Background="Transparent" />
                    <TextBlock Name="WPFGuidedSummarySubtitle" FontSize="14" TextWrapping="Wrap" Foreground="{DynamicResource MainForegroundColor}" Background="Transparent" Opacity="0.8" Margin="0,6,0,0" />
                </StackPanel>
                <Border Grid.Row="1" BorderBrush="{DynamicResource BorderColor}" BorderThickness="1" CornerRadius="6" Margin="0,16,0,10">
                    <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                        <StackPanel Name="WPFGuidedSummaryList" />
                    </ScrollViewer>
                </Border>
                <TextBlock Name="WPFGuidedSummaryNote" Grid.Row="2" FontSize="13" TextWrapping="Wrap" Foreground="{DynamicResource MainForegroundColor}" Background="Transparent" Opacity="0.8" Margin="0,0,0,12" />
                <DockPanel Grid.Row="3" LastChildFill="False">
                    <Button Name="WPFGuidedSummaryBack" DockPanel.Dock="Left" Content="Atrás" Width="Auto" MinWidth="150" Height="40" FontSize="15" Margin="0" />
                    <Button Name="WPFGuidedApply" DockPanel.Dock="Right" Content="Aplicar" Width="Auto" MinWidth="170" Height="40" FontSize="15" Margin="10,0,0,0" Style="{DynamicResource GuidedPrimaryButton}" />
                    <Button Name="WPFGuidedReview" DockPanel.Dock="Right" Content="Revisar en modo avanzado" Width="Auto" MinWidth="150" Height="40" FontSize="15" Margin="0" />
                </DockPanel>
            </Grid>

            <ScrollViewer Name="WPFGuidedDone" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Visibility="Collapsed">
                <StackPanel MaxWidth="680" Margin="32,40" HorizontalAlignment="Center" VerticalAlignment="Center">
                    <TextBlock Name="WPFGuidedDoneTitle" FontSize="28" FontWeight="Bold" TextAlignment="Center" TextWrapping="Wrap" Foreground="{DynamicResource MainForegroundColor}" Background="Transparent" />
                    <TextBlock Name="WPFGuidedDoneText" FontSize="15" TextAlignment="Center" TextWrapping="Wrap" Foreground="{DynamicResource MainForegroundColor}" Background="Transparent" Opacity="0.9" Margin="0,14,0,20" />
                    <Border Name="WPFGuidedErrors" Background="{DynamicResource TweakHelpSectionColor}" BorderBrush="#E07B24" BorderThickness="1" CornerRadius="6" Padding="14,12" Margin="0,0,0,20" Visibility="Collapsed">
                        <ScrollViewer MaxHeight="220" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                            <StackPanel Name="WPFGuidedErrorsList" />
                        </ScrollViewer>
                    </Border>
                    <StackPanel Name="WPFGuidedJobPanel" Margin="0,0,0,20">
                        <TextBlock Name="WPFGuidedJobLabel" FontSize="13" TextWrapping="Wrap" Foreground="{DynamicResource MainForegroundColor}" Background="Transparent" Opacity="0.8" Margin="0,0,0,6" />
                        <ProgressBar Name="WPFGuidedJobProgress" Height="8" Minimum="0" Maximum="100" Value="0" Style="{DynamicResource RoundedProgressBarStyle}" Foreground="{DynamicResource ToggleButtonOnColor}" />
                    </StackPanel>
                    <WrapPanel Name="WPFGuidedDoneButtons" HorizontalAlignment="Center" Visibility="Collapsed">
                        <Button Name="WPFGuidedDoneAdvanced" Content="Ir al modo avanzado" Width="Auto" MinWidth="150" Height="40" FontSize="15" Margin="5,0" />
                        <Button Name="WPFGuidedDoneHome" Content="Volver al inicio" Width="Auto" MinWidth="150" Height="40" FontSize="15" Margin="5,0" />
                        <Button Name="WPFGuidedRestart" Content="Reiniciar ahora" Width="Auto" MinWidth="150" Height="40" FontSize="15" Margin="5,0" Style="{DynamicResource GuidedPrimaryButton}" />
                    </WrapPanel>
                </StackPanel>
            </ScrollViewer>
        </Grid>
    </Grid>
</Window>

'@
Write-Host "APBOptimizer - Tweaks (basado en WinUtil)"

$sync.preferences.theme = "Auto"

#===========================================================================
# Headless runs never build a window
#===========================================================================

if ($Preset -or $Config) {
    $headlessCode = 1
    try {
        Initialize-WinUtilRunspacePool | Out-Null

        if ($Preset) {
            if (-not $sync.configs.preset.$Preset) {
                throw "There is no preset called '$Preset'. Available: $(($sync.configs.preset.PSObject.Properties.Name) -join ', ')"
            }
            Write-WinUtilLog -Component "AutoRun" -Message "Applying preset '$Preset'."
            # SkipUnknown so a retired entry in a preset is named and stepped over rather than
            # ending a headless run that has nobody to read the error
            $skipped = @(Update-WinUtilSelections -flatJson $sync.configs.preset.$Preset -SkipUnknown)
            if ($skipped.Count -gt 0) {
                Write-WinUtilLog -Level "WARN" -Component "AutoRun" -Message "Preset '$Preset' names $($skipped.Count) entr(y/ies) this version does not have: $($skipped -join ', ')"
            }
        }

        # Both may be given: the preset sets a baseline and the config adds to it
        if ($Config) {
            Write-WinUtilLog -Component "AutoRun" -Message "Importing selections from '$Config'."
            Invoke-WPFImpex -type "import" -Config $Config -Merge:([bool]$Preset) -ThrowOnError
        }

        $summary = Invoke-WinUtilAutoRun
        $headlessCode = Write-WinUtilAutoRunSummary -Summary $summary
    } catch {
        Write-WinUtilErrorRecord -ErrorRecord $_ -Component "AutoRun" -Context "Headless run"
        Write-Host "WinUtil could not complete the headless run: $($_.Exception.Message)" -ForegroundColor Red
        $headlessCode = 1
    } finally {
        Close-WinUtilRunspacePool
        [System.GC]::Collect()
        Stop-Transcript | Out-Null
    }

    # An isolated elevated child and an explicit file launch own their process. The documented
    # in-memory invocation runs inside the caller's terminal and must return without closing it.
    if ($env:WINUTIL_HEADLESS_CHILD -eq "1" -or $script:WinUtilIsFileProcess) {
        exit $headlessCode
    }
    $global:LASTEXITCODE = $headlessCode
    return $headlessCode
}

#===========================================================================
# Start the interface on its own thread and manage it from here
#===========================================================================
#
# The main thread stays out of the window's way. It creates the dedicated STA runspace the
# interface lives on, waits for that window to close, and reports anything the interface
# thread failed with. Work started from the interface goes to the worker pool through
# Start-WinUtilJob, so neither the window nor this thread is ever blocked by it.

$sync.UIRunspace = [runspacefactory]::CreateRunspace($Host, (New-WinUtilSessionState))
$sync.UIRunspace.ApartmentState = "STA"
$sync.UIRunspace.ThreadOptions = "ReuseThread"
$sync.UIRunspace.Open()

$uiShell = [powershell]::Create()
$uiShell.Runspace = $sync.UIRunspace
[void]$uiShell.AddScript({ Start-WinUtilUserInterface })

Write-WinUtilLog -Component "UI" -Message "Starting the interface thread."
$uiHandle = $uiShell.BeginInvoke()

# This thread has nothing to do but wait, so it pays for the overlay render rather than
# leaving it to the thread that is building the window
Start-WinUtilAssetRendering | Out-Null

$uiHandle.AsyncWaitHandle.WaitOne() | Out-Null

$uiFailed = $false
try {
    $uiShell.EndInvoke($uiHandle) | Out-Null
} catch {
    $uiFailed = $true
    Write-WinUtilErrorRecord -ErrorRecord $_ -Component "UI" -Context "Interface thread stopped"
}

foreach ($uiWarning in $uiShell.Streams.Warning) {
    Write-WinUtilLog -Level "WARN" -Component "UI" -Message $uiWarning.Message
}

foreach ($uiError in $uiShell.Streams.Error) {
    Write-WinUtilErrorRecord -ErrorRecord $uiError -Component "UI" -Context "Interface thread"
}

$uiShell.Dispose()
$sync.UIRunspace.Dispose()
$sync.Remove("UIRunspace")

# The window may have been closed over a job that the user chose to let finish. It is still on
# the worker pool, so the pool cannot be closed until it is done.
Wait-WinUtilRemainingWork

Close-WinUtilRunspacePool
[System.GC]::Collect()
Write-Host "Bye bye!" -ForegroundColor Cyan
Stop-Transcript

if ($uiFailed) {
    $global:LASTEXITCODE = 1
    if ($script:WinUtilIsFileProcess) { exit 1 }
    return 1
}


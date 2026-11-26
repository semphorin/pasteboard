<#
.SYNOPSIS
  Build and install / update / uninstall pasteboard on Windows.

.DESCRIPTION
  Install: builds the release exe (no console window), copies it to -Prefix,
  writes a default pasteboard.conf (never overwrites an existing one), adds a
  Private-profile inbound firewall rule and registers a logon Scheduled Task.
  Update: rebuilds and swaps the exe of an existing install, then restarts it.
  Uninstall: removes the task, firewall rule and exe (-Purge also deletes
  history and config). Never installs Rust.

  Keep this file pure ASCII: Windows PowerShell 5.1 reads BOM-less scripts in
  the ANSI code page. Non-ASCII glyphs are built with [char] codes below.

.EXAMPLE
  .\install.ps1 -DryRun
  .\install.ps1                     # from an elevated PowerShell
  .\install.ps1 -Update
  .\install.ps1 -Uninstall -Purge   # or: .\uninstall.ps1 -Purge
  .\install.ps1 --update --dry-run  # install.sh-style flags work too
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    $Port = 9911,   # untyped: validated below so --port/-Port errors read the same
    [string]$Prefix,
    [switch]$BuildOnly,
    [switch]$Update,
    [switch]$Uninstall,
    [switch]$Purge,
    [switch]$Yes,
    [switch]$DryRun,
    [switch]$Help,
    # install.sh-style flags (--update, --dry-run, --port 9911, --port=9911, ...)
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest
)

$ErrorActionPreference = 'Stop'
$PortGiven = $PSBoundParameters.ContainsKey('Port')
$PrefixGiven = $PSBoundParameters.ContainsKey('Prefix')

function Show-Usage {
    Write-Host @'
Usage: .\install.ps1 [mode] [options]      (install.sh-style --flags also work)

Modes (default: install, or upgrade an existing install):
  -Update      / --update       rebuild + replace the exe of an existing install, restart
  -BuildOnly   / --build-only   only run cargo build --release
  -Uninstall   / --uninstall    remove task, firewall rule and exe (keeps history)

Options:
  -Port N      / --port N       port for a NEW pasteboard.conf (default 9911)
  -Prefix DIR  / --prefix DIR   install dir (default %LOCALAPPDATA%\Pasteboard)
  -Purge       / --purge        with uninstall: also delete history and config
  -Yes         / --yes          with purge: skip the confirmation
  -DryRun      / --dry-run      print every action without executing it
  -Help        / --help         show this help
'@
}

# Map install.sh-style arguments onto the PowerShell parameters.
$Rest = @($Rest | Where-Object { $_ -ne $null -and $_ -ne '' })
for ($i = 0; $i -lt $Rest.Count; $i++) {
    $arg = $Rest[$i]
    $val = $null
    if ($arg -match '^--?([A-Za-z-]+)=(.*)$') { $arg = "--$($Matches[1])"; $val = $Matches[2] }
    $next = {
        if ($null -ne $script:val) { return $script:val }
        $script:i++
        if ($script:i -ge $Rest.Count) { Write-Host "missing value for $arg" -ForegroundColor Red; Show-Usage; exit 2 }
        $Rest[$script:i]
    }
    switch -regex ($arg.ToLower()) {
        '^--update$' { $Update = $true; continue }
        '^--build-only$' { $BuildOnly = $true; continue }
        '^--uninstall$' { $Uninstall = $true; continue }
        '^--purge$' { $Purge = $true; continue }
        '^(--yes|-y)$' { $Yes = $true; continue }
        '^--dry-run$' { $DryRun = $true; continue }
        '^(--help|-h|-\?|/\?|help)$' { $Help = $true; continue }
        '^--port$' {
            $v = & $next
            if ($v -notmatch '^\d+$' -or [long]$v -lt 1 -or [long]$v -gt 65535) { Write-Host "invalid --port: $v" -ForegroundColor Red; exit 2 }
            $Port = [int]$v; $PortGiven = $true; continue
        }
        '^--prefix$' { $Prefix = & $next; $PrefixGiven = $true; continue }
        default { Write-Host "unknown argument: $($Rest[$i])" -ForegroundColor Red; Show-Usage; exit 2 }
    }
}
if ($Help) { Show-Usage; exit 0 }
if ("$Port" -notmatch '^\d+$' -or [long]"$Port" -lt 1 -or [long]"$Port" -gt 65535) {
    Write-Host "invalid port: $Port (expected 1-65535)" -ForegroundColor Red; exit 2
}
$Port = [int]"$Port"

# Re-run hint built from the final values (not $MyInvocation inside a function).
$RerunArgs = (@(
        $(if ($Update) { '-Update' }), $(if ($BuildOnly) { '-BuildOnly' }), $(if ($Uninstall) { '-Uninstall' }),
        $(if ($Purge) { '-Purge' }), $(if ($Yes) { '-Yes' }), $(if ($DryRun) { '-DryRun' }),
        $(if ($PortGiven) { "-Port $Port" }), $(if ($PrefixGiven) { "-Prefix `"$Prefix`"" })
    ) | Where-Object { $_ }) -join ' '

if ((@($BuildOnly, $Update, $Uninstall) | Where-Object { $_ }).Count -gt 1) {
    Write-Host "Choose only one of -BuildOnly, -Update, -Uninstall." -ForegroundColor Red; exit 2
}
if ($Purge -and -not $Uninstall) { Write-Host "-Purge only works together with -Uninstall." -ForegroundColor Red; exit 2 }

$Mode = if ($BuildOnly) { 'build only' } elseif ($Update) { 'update existing install' } elseif ($Uninstall) { if ($Purge) { 'uninstall + purge (deletes history and config)' } else { 'uninstall' } } else { 'install / upgrade' }
$TaskName = 'Pasteboard'
$RuleName = 'Pasteboard'
$Built = Join-Path $PSScriptRoot 'target\release\pasteboard.exe'

# ------------------------------------------------------------- terminal UI --
$Tty = (-not [Console]::IsOutputRedirected) -and (-not $env:NO_COLOR)
if ($Tty) {
    $G = @{ Full = [string][char]0x2588; Empty = [string][char]0x2591; Ok = [string][char]0x2713; Fail = [string][char]0x2717
        Skip = [string][char]0x00B7; Arrow = [string][char]0x2192; TL = [string][char]0x250C; BL = [string][char]0x2514
        VL = [string][char]0x2502; HL = [string][char]0x2500 }
} else {
    $G = @{ Full = '#'; Empty = '-'; Ok = 'ok'; Fail = 'x'; Skip = '-'; Arrow = '->'; TL = '+'; BL = '+'; VL = '|'; HL = '-' }
}
$script:StepN = 0
$script:Total = 1
$script:Current = ''
$script:LastCmd = ''
$script:Warnings = New-Object System.Collections.Generic.List[string]

function Bar([int]$cur, [int]$tot, [int]$w) {
    $f = if ($tot -gt 0) { [math]::Floor($cur * $w / $tot) } else { $w }
    if ($f -gt $w) { $f = $w }
    ($G.Full * $f) + ($G.Empty * ($w - $f))
}
function Step([string]$title) {
    $script:StepN++
    $script:Current = $title
    Write-Host ''
    Write-Host (' ' + (Bar $script:StepN $script:Total 20)) -ForegroundColor Cyan -NoNewline
    Write-Host (' {0}/{1}  ' -f $script:StepN, $script:Total) -ForegroundColor DarkGray -NoNewline
    Write-Host $title -ForegroundColor White
    Write-Progress -Id 1 -Activity "pasteboard installer: $Mode" -Status ("Step {0}/{1}: {2}" -f $script:StepN, $script:Total, $title) `
        -PercentComplete ([int](($script:StepN - 1) * 100 / $script:Total))
}
function Info([string]$m) { Write-Host "   $m" }
function Shown([string]$cmd) { Write-Host "   `$ $cmd" -ForegroundColor DarkGray }
function Ok([string]$m) { Write-Host "   $($G.Ok) " -ForegroundColor Green -NoNewline; Write-Host $m }
function Skip([string]$m) { Write-Host "   $($G.Skip) $m" -ForegroundColor DarkGray }
function Warn([string]$m) { Write-Host "   ! $m" -ForegroundColor Yellow; $script:Warnings.Add($m) }
function Die([string]$m, [string[]]$details = @()) {
    Write-Progress -Id 1 -Activity 'pasteboard installer' -Completed
    Write-Host ''
    Write-Host "   $($G.Fail) $m" -ForegroundColor Red
    foreach ($d in $details) { Write-Host "     $d" }
    exit 1
}
# Act "command as shown" { action }: print, then run unless -DryRun.
function Act([string]$cmd, [scriptblock]$action) {
    $script:LastCmd = $cmd
    Shown $cmd
    if (-not $DryRun) { & $action }
}
function Banner {
    $line = $G.HL * 52
    Write-Host ''
    Write-Host (" {0}{1}{1} pasteboard installer {2}" -f $G.TL, $G.HL, ($G.HL * 30)) -ForegroundColor DarkGray
    $os = (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption
    $rows = [ordered]@{ os = "$os ($env:PROCESSOR_ARCHITECTURE)"; action = $Mode; prefix = $Prefix; user = $script:TaskUser }
    if (-not ($BuildOnly -or $Update -or $Uninstall)) { $rows.port = if ($PortGiven) { "$Port" } else { "$Port (default)" } }
    foreach ($k in $rows.Keys) {
        Write-Host " $($G.VL) " -ForegroundColor DarkGray -NoNewline
        Write-Host ('{0,-8} {1}' -f $k, $rows[$k])
    }
    if ($DryRun) { Write-Host " $($G.VL) " -ForegroundColor DarkGray -NoNewline; Write-Host 'dry-run  nothing will be changed' -ForegroundColor Yellow }
    Write-Host " $($G.BL)$line" -ForegroundColor DarkGray
}
function Summary([string]$title, [int]$port = 0) {
    Write-Progress -Id 1 -Activity 'pasteboard installer' -Completed
    Write-Host ''
    if ($DryRun) { Write-Host " $($G.Ok) dry run complete: nothing was changed" -ForegroundColor Green }
    else { Write-Host " $($G.Ok) $title" -ForegroundColor Green }
    if ($port -gt 0) {
        Info "open     http://$(Get-LanIp):$port"
        Info "config   $Conf   (then: .\install.ps1 -Update, or restart the '$TaskName' task)"
        Info "update   .\install.ps1 -Update      remove   .\uninstall.ps1"
    }
    if ($script:Warnings.Count -gt 0) {
        Write-Host ''
        Write-Host " $($script:Warnings.Count) warning(s):" -ForegroundColor Yellow
        foreach ($w in $script:Warnings) { Write-Host "   ! $w" -ForegroundColor Yellow }
    }
}

# --------------------------------------------------------------- helpers ----
function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Require-Admin {
    if (Test-Admin) { Ok 'running elevated (Administrator)'; return }
    if ($DryRun) { Warn 'not elevated: a real run needs "Run as Administrator"'; return }
    Die 'Administrator rights are needed (firewall rule + scheduled task).' @(
        "Open PowerShell with 'Run as Administrator' and re-run:",
        "  cd `"$PSScriptRoot`"; .\install.ps1 $RerunArgs")
}
# The interactive desktop user (owner of explorer.exe in this session). When an
# admin elevates with a different account, install for the desktop user anyway.
function Get-DesktopUser {
    try {
        $sid = (Get-Process -Id $PID).SessionId
        $exp = Get-CimInstance Win32_Process -Filter "Name='explorer.exe' AND SessionId=$sid" | Select-Object -First 1
        if (-not $exp) { return $null }
        $o = Invoke-CimMethod -InputObject $exp -MethodName GetOwner
        $s = Invoke-CimMethod -InputObject $exp -MethodName GetOwnerSid
        if ($o.ReturnValue -ne 0) { return $null }
        [pscustomobject]@{ Name = "$($o.Domain)\$($o.User)"; Sid = $s.Sid }
    } catch { $null }
}
function Get-DefaultRoute {
    Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Sort-Object { $_.RouteMetric + (Get-NetIPInterface -InterfaceIndex $_.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).InterfaceMetric } |
        Select-Object -First 1
}
function Get-LanIp {
    $r = Get-DefaultRoute
    if ($r) {
        $ip = Get-NetIPAddress -InterfaceIndex $r.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($ip) { return $ip.IPAddress }
    }
    'localhost'
}
function Get-ConfPort([string]$path) {
    $m = Select-String -LiteralPath $path -Pattern '^\s*port\s*=\s*(\d+)' -ErrorAction SilentlyContinue | Select-Object -Last 1
    if ($m) { [int]$m.Matches[0].Groups[1].Value } else { 9911 }
}
function Get-FileHashShort([string]$path) {
    if (Test-Path -LiteralPath $path) { (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.Substring(0, 12).ToLower() } else { '' }
}
function Get-Version([string]$exe) {
    if (-not (Test-Path -LiteralPath $exe)) { return 'not installed' }
    # The no-console exe has no stdout handle, so ask via a redirected process.
    # Builds older than --version print a config error and exit 1: report 'unknown version'.
    try {
        $psi = New-Object Diagnostics.ProcessStartInfo $exe, '--version'
        $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
        $p = [Diagnostics.Process]::Start($psi)
        $out = $p.StandardOutput.ReadToEnd().Trim(); [void]$p.StandardError.ReadToEnd()
        if (-not $p.WaitForExit(3000)) { $p.Kill(); return 'unknown version' }
        if ($p.ExitCode -eq 0 -and $out -like 'pasteboard *') { $out } else { 'unknown version' }
    } catch { 'unknown version' }
}
function Stop-Pasteboard {
    $running = @(Get-Process pasteboard -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $Exe })
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $running -and -not ($task -and $task.State -eq 'Running')) { Skip 'not running'; return }
    if ($task) { Act "Stop-ScheduledTask -TaskName $TaskName" { Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue } }
    foreach ($p in $running) {
        Act "Stop-Process -Id $($p.Id)   # $Exe" {
            Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
            Wait-Process -Id $p.Id -Timeout 10 -ErrorAction SilentlyContinue
        }
    }
    if (-not $DryRun) { Ok 'stopped' }
}
# Copy the exe, retrying while Windows still holds the old image open.
function Copy-Exe {
    Act "Copy-Item `"$Built`" `"$Exe`" -Force" {
        $last = $null
        for ($i = 0; $i -lt 20; $i++) {
            try { Copy-Item -LiteralPath $Built -Destination $Exe -Force; $last = $null; break }
            catch { $last = $_; Start-Sleep -Milliseconds 250 }
        }
        if ($last) { Die "could not replace $Exe (still in use?)" @("$($last.Exception.Message)") }
    }
}
function Test-Healthy([int]$port) {
    if ($DryRun) { Shown "wait for: GET http://127.0.0.1:$port/ = 200"; return }
    for ($i = 0; $i -lt 24; $i++) {
        try {
            $r = Invoke-WebRequest -Uri "http://127.0.0.1:$port/" -UseBasicParsing -TimeoutSec 2
            if ($r.StatusCode -eq 200) { Ok "http://127.0.0.1:$port/ answered 200"; return }
        } catch { }
        Start-Sleep -Milliseconds 250
    }
    $info = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue
    $proc = Get-Process pasteboard -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $Exe }
    $details = @("task last result: $(if ($info) { '0x{0:X}' -f $info.LastTaskResult } else { 'n/a' })",
        "process running:  $([bool]$proc)",
        "Check the port and $Conf, then run the exe by hand to see errors:",
        "  & `"$Exe`" --config `"$Conf`"   (a regular 'cargo build --release' build prints to the console)")
    if ($proc) { Warn "pasteboard is running but did not answer on 127.0.0.1:$port (is 'bind' set to a specific address?)"; return }
    Die 'pasteboard did not start' $details
}
function Build {
    $total = @(Select-String -LiteralPath (Join-Path $PSScriptRoot 'Cargo.lock') -Pattern '^\[\[package\]\]').Count
    if ($total -lt 1) { $total = 20 }
    $cmd = 'cargo build --release --locked --features no-console'
    $script:LastCmd = $cmd
    Shown "cd `"$PSScriptRoot`"; $cmd"
    if ($DryRun) { Skip 'dry-run: build skipped'; return }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $n = 0
    $log = New-Object System.Collections.Generic.List[string]
    Push-Location $PSScriptRoot
    # cargo reports progress on stderr; PS 5.1 turns those lines into error
    # records under redirection, so judge success by exit code only.
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & cargo build --release --locked --features no-console 2>&1 | ForEach-Object {
            $line = "$_"
            $log.Add($line)
            if ($line -match '^\s*Compiling (\S+ \S+)') {
                $n++
                $pct = [math]::Min(100, [int]($n * 100 / $total))
                Write-Progress -Id 2 -ParentId 1 -Activity 'cargo build --release' -Status "compiling $($Matches[1]) ($n/$total)" -PercentComplete $pct
                if ($Tty) {
                    Write-Host ("`r   " + (Bar $n $total 24)) -ForegroundColor Cyan -NoNewline
                    Write-Host ((' {0,2}/{1}  compiling {2}' -f $n, $total, $Matches[1]).PadRight(56)) -NoNewline
                } else { Write-Host "     compiling $($Matches[1]) ($n/$total)" }
            } elseif ($line -match '^\s*warning') {
                if ($Tty) { Write-Host ("`r" + (' ' * 90) + "`r") -NoNewline }
                Write-Host "     $line" -ForegroundColor Yellow
            }
        }
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $prev; Pop-Location }
    Write-Progress -Id 2 -ParentId 1 -Activity 'cargo build --release' -Completed
    if ($Tty) { Write-Host ("`r" + (' ' * 90) + "`r") -NoNewline }
    if ($code -ne 0) {
        Write-Host '     --- last 25 lines of cargo output ---'
        $log | Select-Object -Last 25 | ForEach-Object { Write-Host "     $_" }
        Die "cargo build failed (exit $code)"
    }
    Write-Host ('   ' + (Bar 1 1 24)) -ForegroundColor Cyan -NoNewline
    Write-Host (' {0}/{0}  done' -f $total)
    $kb = [math]::Round((Get-Item -LiteralPath $Built).Length / 1KB)
    Ok ("built target\release\pasteboard.exe ({0} KB, {1}) in {2:N1}s" -f $kb, (Get-Version $Built), $sw.Elapsed.TotalSeconds)
}
function Check-Cargo {
    $c = Get-Command cargo -ErrorAction SilentlyContinue
    if ($c) {
        $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        $v = (& cargo --version 2>&1 | Select-Object -First 1)
        $ErrorActionPreference = $prev
        Ok "cargo: $v"; return
    }
    if ($DryRun) { Warn 'cargo not found (a real run would stop here)'; return }
    Die 'cargo (Rust) not found' @('This script does not install tooling. Install Rust, then re-run:',
        '  winget install Rustlang.Rustup',
        "  (plus Visual Studio Build Tools with the 'Desktop development with C++' workload)")
}

# ------------------------------------------------------- resolve the user ----
# Install for the desktop user even when elevated as another admin account.
$script:TaskUser = "$env:USERDOMAIN\$env:USERNAME"
$DesktopUser = Get-DesktopUser
if ($DesktopUser -and $DesktopUser.Name -ne $script:TaskUser) {
    $script:TaskUser = $DesktopUser.Name
    if (-not $PrefixGiven) {
        $profilePath = (Get-CimInstance Win32_UserProfile -Filter "SID='$($DesktopUser.Sid)'" -ErrorAction SilentlyContinue).LocalPath
        if ($profilePath) { $Prefix = Join-Path $profilePath 'AppData\Local\Pasteboard' }
    }
}
if (-not $Prefix) { $Prefix = Join-Path $env:LOCALAPPDATA 'Pasteboard' }
$Exe = Join-Path $Prefix 'pasteboard.exe'
$Conf = Join-Path $Prefix 'pasteboard.conf'

try {
    Banner
    if ($DesktopUser -and $DesktopUser.Name -ne "$env:USERDOMAIN\$env:USERNAME") {
        Warn "elevated as $env:USERDOMAIN\$env:USERNAME but the desktop user is $($DesktopUser.Name): installing for $($DesktopUser.Name)"
    }

    # ======================================================== uninstall ==
    if ($Uninstall) {
        $script:Total = if ($Purge) { 6 } else { 5 }
        Step 'Checking permissions'
        Require-Admin

        Step 'Stopping pasteboard'
        Stop-Pasteboard

        Step 'Removing the scheduled task'
        if ($DryRun -or (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue)) {
            Act "Unregister-ScheduledTask -TaskName $TaskName -Confirm:`$false" { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false }
            if (-not $DryRun) { Ok 'task removed' }
        } else { Skip "no task named '$TaskName'" }

        Step 'Removing the firewall rule'
        if ($DryRun -or (Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue)) {
            Act "Remove-NetFirewallRule -DisplayName $RuleName" { Get-NetFirewallRule -DisplayName $RuleName | Remove-NetFirewallRule }
            if (-not $DryRun) { Ok 'firewall rule removed' }
        } else { Skip "no firewall rule named '$RuleName'" }

        Step 'Removing the exe'
        if ($DryRun -or (Test-Path -LiteralPath $Exe)) {
            Act "Remove-Item `"$Exe`"" { Remove-Item -LiteralPath $Exe -Force }
            if (-not $DryRun) { Ok "removed $Exe" }
        } else { Skip "$Exe not found" }

        if ($Purge) {
            Step 'Purging history and config'
            $log = Join-Path $Prefix 'data\log.jsonl'
            $count = if (Test-Path -LiteralPath $log) { @(Select-String -LiteralPath $log -Pattern '"op":"add"').Count } else { 0 }
            Info "this permanently deletes $Prefix (about $count history entries + uploaded files)"
            if (-not $DryRun -and -not $Yes) {
                if ([Console]::IsInputRedirected) { Die 'refusing to purge without confirmation' @('Re-run in a PowerShell window, or add -Yes.') }
                $answer = Read-Host '   Type "delete" to confirm'
                if ($answer -ne 'delete') { Die 'purge cancelled; nothing else was removed' @('Task, firewall rule and exe were already removed above.') }
            }
            if ($DryRun -or (Test-Path -LiteralPath $Prefix)) {
                Act "Remove-Item `"$Prefix`" -Recurse -Force" { Remove-Item -LiteralPath $Prefix -Recurse -Force }
            }
            Summary 'pasteboard uninstalled and purged'
        } else {
            Summary 'pasteboard uninstalled'
            Info "kept   $Conf and $(Join-Path $Prefix 'data')   (delete too: .\uninstall.ps1 -Purge)"
        }
        exit 0
    }

    # ======================================================= build only ==
    if ($BuildOnly) {
        $script:Total = 2
        Step 'Checking prerequisites'
        Check-Cargo
        Step 'Building release binary'
        Build
        Summary "build complete $($G.Arrow) $Built"
        exit 0
    }

    # =========================================================== update ==
    if ($Update) {
        $script:Total = 5
        Step 'Checking the existing install'
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if (-not (Test-Path -LiteralPath $Exe) -or -not $task) {
            if ($DryRun) { Warn "no install found at $Prefix (a real run would stop here)" }
            else { Die "pasteboard is not installed at $Prefix" @('Run .\install.ps1 first (or pass the -Prefix you installed to).') }
        } else { Ok "installed: $(Get-Version $Exe) at $Prefix" }
        $EffectivePort = Get-ConfPort $Conf
        if ($PortGiven) { Warn "-Port is ignored by -Update (edit $Conf to change the port)" }
        Check-Cargo
        Require-Admin

        Step 'Building release binary'
        Build

        Step 'Replacing the exe'
        $old = Get-FileHashShort $Exe
        $new = Get-FileHashShort $Built
        $changed = $true
        if (-not $DryRun -and $old -and $old -eq $new) {
            $changed = $false
            Ok "exe unchanged (sha256 $new); nothing to replace"
        } else {
            Info ("sha256 {0} {1} {2}" -f $(if ($old) { $old } else { 'none' }), $G.Arrow, $(if ($new) { $new } else { 'new build' }))
            Stop-Pasteboard
            Copy-Exe
            if (-not $DryRun) { Ok 'exe replaced' }
        }

        Step 'Restarting pasteboard'
        $running = Get-Process pasteboard -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $Exe }
        if (-not $changed -and $running) { Skip 'nothing changed and it is running; restart skipped' }
        else {
            Act "Start-ScheduledTask -TaskName $TaskName" { Start-ScheduledTask -TaskName $TaskName }
            if (-not $DryRun) { Ok 'started' }
        }

        Step 'Checking that it is up'
        Test-Healthy $EffectivePort
        Summary "pasteboard is up to date ($(Get-Version $Exe))" $EffectivePort
        exit 0
    }

    # ========================================================== install ==
    $script:Total = 8
    Step 'Checking prerequisites'
    Check-Cargo
    Require-Admin
    $EffectivePort = $Port
    if (Test-Path -LiteralPath $Conf) {
        $EffectivePort = Get-ConfPort $Conf
        if ($PortGiven -and $EffectivePort -ne $Port) { Warn "-Port $Port ignored: existing $Conf sets port $EffectivePort (edit it to change the port)" }
        else { Ok "existing config found (port $EffectivePort)" }
    }
    $listeners = @(Get-NetTCPConnection -LocalPort $EffectivePort -State Listen -ErrorAction SilentlyContinue)
    $foreign = @($listeners | Where-Object { (Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue).Path -ne $Exe })
    if ($foreign.Count -gt 0) {
        $who = $foreign | ForEach-Object { $p = Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue; "PID $($_.OwningProcess) $($p.ProcessName) $($p.Path)" } | Select-Object -Unique
        Die "port $EffectivePort is already in use" (@($who) + @('Stop that program, or install with -Port N (or edit the installed pasteboard.conf).'))
    } elseif ($listeners.Count -gt 0) { Ok "port $EffectivePort is served by the installed pasteboard (it will be restarted)" }
    else { Ok "port $EffectivePort is free" }

    Step 'Building release binary'
    Build

    Step 'Stopping the running instance'
    Stop-Pasteboard

    Step 'Installing files'
    Act "New-Item -ItemType Directory `"$Prefix`" -Force" { New-Item -ItemType Directory -Force -Path $Prefix | Out-Null }
    Copy-Exe
    if (-not $DryRun) { Ok "exe  $Exe" }

    Step 'Writing configuration'
    if (Test-Path -LiteralPath $Conf) { Ok "keeping existing $Conf (never overwritten)" }
    else {
        $lines = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'pasteboard.conf') | ForEach-Object { $_ -replace '^port = .*', "port = $Port" }
        Act "write $Conf  (port = $Port, UTF-8 without BOM, $($lines.Count) lines)" { [IO.File]::WriteAllLines($Conf, [string[]]$lines) }
        if (-not $DryRun) { Ok "wrote $Conf" }
    }

    Step 'Configuring the firewall'
    Act "New-NetFirewallRule -DisplayName $RuleName -Direction Inbound -Protocol TCP -LocalPort $EffectivePort -Program `"$Exe`" -Action Allow -Profile Private" {
        Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule
        New-NetFirewallRule -DisplayName $RuleName -Direction Inbound -Protocol TCP -LocalPort $EffectivePort `
            -Program $Exe -Action Allow -Profile Private | Out-Null
    }
    if (-not $DryRun) { Ok "inbound TCP $EffectivePort allowed on Private networks" }
    $route = Get-DefaultRoute
    $netProfile = if ($route) { Get-NetConnectionProfile -InterfaceIndex $route.ifIndex -ErrorAction SilentlyContinue } else { $null }
    if ($netProfile -and $netProfile.NetworkCategory -eq 'Public') {
        Warn ("network '{0}' is Public: the Private-only rule does not apply there, so other devices cannot connect. Fix: Settings > Network & internet > {0} > Private network" -f $netProfile.Name)
    } elseif ($netProfile) { Ok "network '$($netProfile.Name)' is $($netProfile.NetworkCategory)" }

    Step 'Registering the logon task'
    Act "Register-ScheduledTask -TaskName $TaskName  (at logon of $script:TaskUser; `"$Exe`" --config `"$Conf`"; restart on failure)" {
        $action = New-ScheduledTaskAction -Execute $Exe -Argument "--config `"$Conf`"" -WorkingDirectory $Prefix
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $script:TaskUser
        $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) `
            -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
            -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew
        $principal = New-ScheduledTaskPrincipal -UserId $script:TaskUser -LogonType Interactive -RunLevel Limited
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
            -Settings $settings -Principal $principal -Force | Out-Null
    }
    Act "Start-ScheduledTask -TaskName $TaskName" { Start-ScheduledTask -TaskName $TaskName }
    if (-not $DryRun) { Ok 'task registered and started' }

    Step 'Checking that it is up'
    Test-Healthy $EffectivePort

    Summary 'pasteboard is installed and running (starts at logon)' $EffectivePort
    exit 0
} catch {
    Write-Progress -Id 1 -Activity 'pasteboard installer' -Completed
    Write-Host ''
    Write-Host ("   {0} step {1}/{2} '{3}' failed: {4}" -f $G.Fail, $script:StepN, $script:Total, $script:Current, $_.Exception.Message) -ForegroundColor Red
    if ($script:LastCmd) { Write-Host "     last command: $script:LastCmd" }
    Write-Host '     Earlier steps were applied. Fix the cause and re-run; the installer is idempotent.'
    exit 1
}

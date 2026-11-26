<#
.SYNOPSIS
  Uninstall pasteboard on Windows (wrapper around install.ps1 -Uninstall).

.EXAMPLE
  .\uninstall.ps1                 # remove task, firewall rule and exe; keep history
  .\uninstall.ps1 -Purge          # also delete history and config (asks to confirm)
  .\uninstall.ps1 -Purge -Yes     # no confirmation
  .\uninstall.ps1 --purge --dry-run   # install.sh-style flags work too
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$Prefix,
    [switch]$Purge,
    [switch]$Yes,
    [switch]$DryRun,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest
)
$forward = @{ Uninstall = $true }
foreach ($k in $PSBoundParameters.Keys) { if ($k -ne 'Rest') { $forward[$k] = $PSBoundParameters[$k] } }
$extra = @($Rest | Where-Object { $_ })
& (Join-Path $PSScriptRoot 'install.ps1') @forward @extra
exit $LASTEXITCODE

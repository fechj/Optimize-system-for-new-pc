[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:ProgramData 'WorkGameBlocker'),
    [switch]$KeepFiles
)

$ErrorActionPreference = 'Stop'
$CommonPath = Join-Path $InstallDir 'scripts\GameBlocker.Common.ps1'
if (Test-Path -LiteralPath $CommonPath) {
    . $CommonPath
} else {
    $script:GameBlockerTaskName = 'WorkGameBlocker Watcher'
    $script:GameBlockerTaskPath = '\WorkGameBlocker\'
    $script:GameBlockerRuleGroup = 'WorkGameBlocker'
    function Assert-GameBlockerAdmin {
        $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $Principal = New-Object Security.Principal.WindowsPrincipal($Identity)
        if (-not $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            throw 'Run this script from PowerShell as Administrator.'
        }
    }
}

Assert-GameBlockerAdmin

try {
    Publish-GameBlockerEvent -InstallDir $InstallDir -Type 'uninstalling' -Message 'Game blocking policy is being removed.'
} catch {
}

Unregister-ScheduledTask -TaskName $script:GameBlockerTaskName -TaskPath $script:GameBlockerTaskPath -Confirm:$false -ErrorAction SilentlyContinue
Remove-NetFirewallRule -Group $script:GameBlockerRuleGroup -ErrorAction SilentlyContinue

if (-not $KeepFiles -and (Test-Path -LiteralPath $InstallDir)) {
    $ResolvedInstallDir = [IO.Path]::GetFullPath($InstallDir)
    $ResolvedProgramData = [IO.Path]::GetFullPath($env:ProgramData)
    if (-not $ResolvedInstallDir.StartsWith($ResolvedProgramData, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove files outside ProgramData: $ResolvedInstallDir"
    }

    Remove-Item -LiteralPath $InstallDir -Recurse -Force
}

Write-Host 'WorkGameBlocker removed.'

[CmdletBinding()]
param(
    [ValidateSet('Block', 'Allow')]
    [string]$Mode = 'Block',
    [ValidateRange(1, 1440)]
    [int]$Minutes = 60,
    [string]$InstallDir = (Join-Path $env:ProgramData 'WorkGameBlocker')
)

$ErrorActionPreference = 'Stop'
. (Join-Path $InstallDir 'scripts\GameBlocker.Common.ps1')

Assert-GameBlockerAdmin

if ($Mode -eq 'Allow') {
    $AllowUntilUtc = [datetime]::UtcNow.AddMinutes($Minutes)
    Set-GameBlockerStateFile -InstallDir $InstallDir -Mode Allow -AllowUntilUtc $AllowUntilUtc
    $ChangedRules = Set-GameBlockerFirewallEnabled -Enabled $false

    Publish-GameBlockerEvent -InstallDir $InstallDir -Type 'access-allowed' -Message "Game access allowed for $Minutes minute(s)." -Data @{
        allowUntilUtc = $AllowUntilUtc.ToString('o')
        firewallRules = $ChangedRules
    }

    Write-Host "Game access allowed until $($AllowUntilUtc.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss'))."
    exit 0
}

Set-GameBlockerStateFile -InstallDir $InstallDir -Mode Block -AllowUntilUtc $null
$ChangedRules = Set-GameBlockerFirewallEnabled -Enabled $true
if ($ChangedRules -eq 0) {
    $ChangedRules = Sync-GameBlockerFirewallRules -InstallDir $InstallDir -Enabled $true
}
$Stopped = Stop-GameBlockerBlockedProcesses -InstallDir $InstallDir

Publish-GameBlockerEvent -InstallDir $InstallDir -Type 'access-blocked' -Message 'Game access blocked.' -Data @{
    firewallRules    = $ChangedRules
    stoppedProcesses = @($Stopped).Count
}

Write-Host 'Game access blocked.'
Write-Host "Stopped processes: $(@($Stopped).Count)"

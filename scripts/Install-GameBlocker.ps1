[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:ProgramData 'WorkGameBlocker'),
    [string]$TelegramBotToken,
    [string]$TelegramChatId,
    [string]$ControlUrl,
    [ValidateRange(5, 3600)]
    [int]$ControlPollSeconds = 15,
    [string]$DeviceId = $env:COMPUTERNAME,
    [switch]$EnableTelegramControl,
    [ValidateRange(2, 300)]
    [int]$TelegramPollSeconds = 5,
    [switch]$NoTelegram,
    [switch]$StartAllowed
)

$ErrorActionPreference = 'Stop'
$SourceRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
. (Join-Path $SourceRoot 'scripts\GameBlocker.Common.ps1')

Assert-GameBlockerAdmin

Stop-ScheduledTask -TaskName $script:GameBlockerTaskName -TaskPath $script:GameBlockerTaskPath -ErrorAction SilentlyContinue
$OldWatcherCount = Stop-GameBlockerExistingWatchers -InstallDir $InstallDir

function Protect-GameBlockerInstallDir {
    param([string]$Path)

    try {
        $DirectorySecurity = New-Object System.Security.AccessControl.DirectorySecurity
        $Inheritance = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
        $Propagation = [System.Security.AccessControl.PropagationFlags]::None
        $AccessType = [System.Security.AccessControl.AccessControlType]::Allow
        $Rights = [System.Security.AccessControl.FileSystemRights]::FullControl

        foreach ($SidValue in @('S-1-5-18', 'S-1-5-32-544')) {
            $Sid = New-Object System.Security.Principal.SecurityIdentifier($SidValue)
            $Rule = New-Object System.Security.AccessControl.FileSystemAccessRule($Sid, $Rights, $Inheritance, $Propagation, $AccessType)
            $DirectorySecurity.AddAccessRule($Rule)
        }

        Set-Acl -LiteralPath $Path -AclObject $DirectorySecurity
    } catch {
        Write-Warning "Could not tighten folder ACLs: $($_.Exception.Message)"
    }
}

$ScriptInstallDir = Join-Path $InstallDir 'scripts'
$ConfigInstallDir = Join-Path $InstallDir 'config'
New-Item -ItemType Directory -Force -Path $ScriptInstallDir, $ConfigInstallDir, (Join-Path $InstallDir 'logs') | Out-Null

Copy-Item -LiteralPath (Join-Path $SourceRoot 'scripts\GameBlocker.Common.ps1') -Destination $ScriptInstallDir -Force
Copy-Item -LiteralPath (Join-Path $SourceRoot 'scripts\Watch-GameProcesses.ps1') -Destination $ScriptInstallDir -Force
Copy-Item -LiteralPath (Join-Path $SourceRoot 'scripts\Set-GameBlockerState.ps1') -Destination $ScriptInstallDir -Force
Copy-Item -LiteralPath (Join-Path $SourceRoot 'scripts\Uninstall-GameBlocker.ps1') -Destination $ScriptInstallDir -Force
Copy-Item -LiteralPath (Join-Path $SourceRoot 'config\blocked-apps.json') -Destination $ConfigInstallDir -Force

Protect-GameBlockerInstallDir -Path $InstallDir

$TelegramEnabled = -not $NoTelegram -and -not [string]::IsNullOrWhiteSpace($TelegramBotToken) -and -not [string]::IsNullOrWhiteSpace($TelegramChatId)
$TelegramConfig = [ordered]@{
    enabled        = [bool]$TelegramEnabled
    botToken       = if ($TelegramEnabled) { $TelegramBotToken } else { $null }
    chatId         = if ($TelegramEnabled) { $TelegramChatId } else { $null }
    controlEnabled = [bool]($TelegramEnabled -and $EnableTelegramControl)
    allowedChatId  = if ($TelegramEnabled) { $TelegramChatId } else { $null }
    pollSeconds    = $TelegramPollSeconds
}
$TelegramConfig | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $InstallDir 'telegram.json') -Encoding UTF8
$InitializedTelegramOffset = Initialize-GameBlockerTelegramOffset -InstallDir $InstallDir

$ControlEnabled = -not [string]::IsNullOrWhiteSpace($ControlUrl)
$ControlConfig = [ordered]@{
    enabled     = [bool]$ControlEnabled
    url         = if ($ControlEnabled) { $ControlUrl } else { $null }
    pollSeconds = $ControlPollSeconds
    deviceId    = $DeviceId
}
$ControlConfig | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $InstallDir 'control.json') -Encoding UTF8

if ($StartAllowed) {
    Set-GameBlockerStateFile -InstallDir $InstallDir -Mode Allow -AllowUntilUtc ([datetime]::UtcNow.AddMinutes(60))
} else {
    Set-GameBlockerStateFile -InstallDir $InstallDir -Mode Block -AllowUntilUtc $null
}

$FirewallRuleCount = Sync-GameBlockerFirewallRules -InstallDir $InstallDir -Enabled (-not $StartAllowed)

$PowerShellExe = Join-Path $PSHOME 'powershell.exe'
$WatcherPath = Join-Path $InstallDir 'scripts\Watch-GameProcesses.ps1'
$Action = New-ScheduledTaskAction -Execute $PowerShellExe -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$WatcherPath`" -InstallDir `"$InstallDir`""
$Trigger = New-ScheduledTaskTrigger -AtStartup
$Principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$Settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)

Unregister-ScheduledTask -TaskName $script:GameBlockerTaskName -TaskPath $script:GameBlockerTaskPath -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $script:GameBlockerTaskName -TaskPath $script:GameBlockerTaskPath -Action $Action -Trigger $Trigger -Principal $Principal -Settings $Settings -Description 'Stops configured game launchers and logs only blocked launch attempts.' | Out-Null
Start-ScheduledTask -TaskName $script:GameBlockerTaskName -TaskPath $script:GameBlockerTaskPath

Publish-GameBlockerEvent -InstallDir $InstallDir -Type 'installed' -Message 'Game blocking policy installed.' -Data @{
    firewallRules = $FirewallRuleCount
    telegram      = $TelegramEnabled
    telegramControl = [bool]($TelegramEnabled -and $EnableTelegramControl)
    initializedTelegramOffset = $InitializedTelegramOffset
    remoteControl = $ControlEnabled
    stoppedOldWatchers = $OldWatcherCount
    mode          = if ($StartAllowed) { 'Allow' } else { 'Block' }
}

Write-Host "Installed WorkGameBlocker to $InstallDir"
Write-Host "Scheduled task: $($script:GameBlockerTaskPath)$($script:GameBlockerTaskName)"
Write-Host "Firewall rules created: $FirewallRuleCount"
Write-Host "Telegram control enabled: $([bool]($TelegramEnabled -and $EnableTelegramControl))"
Write-Host "Remote control enabled: $ControlEnabled"

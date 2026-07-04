[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:ProgramData 'WorkGameBlocker')
)

$ErrorActionPreference = 'Stop'
. (Join-Path $InstallDir 'scripts\GameBlocker.Common.ps1')

$LastLoggedUtcByKey = @{}
$LastRemotePollUtc = [datetime]::MinValue
$LastTelegramPollUtc = [datetime]::MinValue

function Test-GameBlockerLogDue {
    param(
        [string]$Key,
        [int]$CooldownSeconds
    )

    $Now = [datetime]::UtcNow
    if (-not $LastLoggedUtcByKey.ContainsKey($Key)) {
        $LastLoggedUtcByKey[$Key] = $Now
        return $true
    }

    if (($Now - $LastLoggedUtcByKey[$Key]).TotalSeconds -ge $CooldownSeconds) {
        $LastLoggedUtcByKey[$Key] = $Now
        return $true
    }

    return $false
}

function Select-GameBlockerRemoteCommand {
    param(
        [object]$RemoteDocument,
        [string]$DeviceId
    )

    if ($null -eq $RemoteDocument) {
        return $null
    }

    if ($RemoteDocument.PSObject.Properties['devices'] -and $null -ne $RemoteDocument.devices) {
        $DeviceProperty = $RemoteDocument.devices.PSObject.Properties[$DeviceId]
        if ($DeviceProperty -and $null -ne $DeviceProperty.Value) {
            return $DeviceProperty.Value
        }
    }

    if ($RemoteDocument.PSObject.Properties['default'] -and $null -ne $RemoteDocument.default) {
        return $RemoteDocument.default
    }

    return $RemoteDocument
}

function Get-GameBlockerRemoteVersion {
    param([object]$Command)

    foreach ($PropertyName in @('version', 'updatedAtUtc', 'id')) {
        if ($Command.PSObject.Properties[$PropertyName] -and -not [string]::IsNullOrWhiteSpace([string]$Command.$PropertyName)) {
            return [string]$Command.$PropertyName
        }
    }

    return ($Command | ConvertTo-Json -Depth 8 -Compress)
}

function Apply-GameBlockerRemoteControl {
    param([string]$InstallDir)

    $Control = Get-GameBlockerControlConfig -InstallDir $InstallDir
    if (-not $Control.enabled -or [string]::IsNullOrWhiteSpace([string]$Control.url)) {
        return
    }

    $PollSeconds = [Math]::Max(5, [int]$Control.pollSeconds)
    $Now = [datetime]::UtcNow
    if (($Now - $script:LastRemotePollUtc).TotalSeconds -lt $PollSeconds) {
        return
    }
    $script:LastRemotePollUtc = $Now

    $StoredControlState = Get-GameBlockerRemoteControlState -InstallDir $InstallDir

    try {
        $RemoteDocument = Invoke-RestMethod -Method Get -Uri ([string]$Control.url) -TimeoutSec 10
        $Command = Select-GameBlockerRemoteCommand -RemoteDocument $RemoteDocument -DeviceId ([string]$Control.deviceId)
        if ($null -eq $Command -or -not $Command.PSObject.Properties['mode']) {
            Set-GameBlockerRemoteControlState -InstallDir $InstallDir -LastAppliedVersion ([string]$StoredControlState.lastAppliedVersion) -LastPollUtc $Now.ToString('o') -LastErrorUtc ([string]$StoredControlState.lastErrorUtc)
            return
        }

        $Mode = [string]$Command.mode
        if ($Mode -notin @('Block', 'Allow')) {
            throw "Remote control mode must be Block or Allow, got: $Mode"
        }

        $Version = Get-GameBlockerRemoteVersion -Command $Command
        if ($Version -eq [string]$StoredControlState.lastAppliedVersion) {
            Set-GameBlockerRemoteControlState -InstallDir $InstallDir -LastAppliedVersion $Version -LastPollUtc $Now.ToString('o') -LastErrorUtc ([string]$StoredControlState.lastErrorUtc)
            return
        }

        if ($Mode -eq 'Allow') {
            $AllowUntilUtc = $null
            if ($Command.PSObject.Properties['allowUntilUtc'] -and -not [string]::IsNullOrWhiteSpace([string]$Command.allowUntilUtc)) {
                $AllowUntilUtc = ([datetime]::Parse([string]$Command.allowUntilUtc)).ToUniversalTime()
            } elseif ($Command.PSObject.Properties['minutes']) {
                $Minutes = [Math]::Min(1440, [Math]::Max(1, [int]$Command.minutes))
                $AllowUntilUtc = $Now.AddMinutes($Minutes)
            } else {
                $AllowUntilUtc = $Now.AddMinutes(60)
            }

            if ($AllowUntilUtc -le $Now) {
                Set-GameBlockerStateFile -InstallDir $InstallDir -Mode Block -AllowUntilUtc $null
                Set-GameBlockerFirewallEnabled -Enabled $true | Out-Null
                Publish-GameBlockerEvent -InstallDir $InstallDir -Type 'remote-block' -Message 'Remote control requested Block because allowUntilUtc is expired.'
            } else {
                Set-GameBlockerStateFile -InstallDir $InstallDir -Mode Allow -AllowUntilUtc $AllowUntilUtc
                Set-GameBlockerFirewallEnabled -Enabled $false | Out-Null
                Publish-GameBlockerEvent -InstallDir $InstallDir -Type 'remote-allow' -Message "Remote control allowed game access until $($AllowUntilUtc.ToString('o'))." -Data @{
                    allowUntilUtc = $AllowUntilUtc.ToString('o')
                }
            }
        } else {
            Set-GameBlockerStateFile -InstallDir $InstallDir -Mode Block -AllowUntilUtc $null
            Set-GameBlockerFirewallEnabled -Enabled $true | Out-Null
            $Stopped = Stop-GameBlockerBlockedProcesses -InstallDir $InstallDir
            Publish-GameBlockerEvent -InstallDir $InstallDir -Type 'remote-block' -Message 'Remote control blocked game access.' -Data @{
                stoppedProcesses = @($Stopped).Count
            }
        }

        Set-GameBlockerRemoteControlState -InstallDir $InstallDir -LastAppliedVersion $Version -LastPollUtc $Now.ToString('o') -LastErrorUtc ([string]$StoredControlState.lastErrorUtc)
    } catch {
        Set-GameBlockerRemoteControlState -InstallDir $InstallDir -LastAppliedVersion ([string]$StoredControlState.lastAppliedVersion) -LastPollUtc $Now.ToString('o') -LastErrorUtc $Now.ToString('o')
        Write-GameBlockerLocalEvent -InstallDir $InstallDir -Type 'remote-control-error' -Message $_.Exception.Message
    }
}

function Send-GameBlockerTelegramReply {
    param(
        [object]$Telegram,
        [string]$Text
    )

    Send-GameBlockerTelegramDirect -BotToken ([string]$Telegram.botToken) -ChatId ([string]$Telegram.allowedChatId) -Text $Text
}

function Get-GameBlockerStatusText {
    param([string]$InstallDir)

    $State = Get-GameBlockerState -InstallDir $InstallDir
    $Mode = if ([string]::IsNullOrWhiteSpace([string]$State.mode)) { 'Block' } else { [string]$State.mode }
    $Text = "Status: $Mode"
    if ($Mode -eq 'Allow' -and -not [string]::IsNullOrWhiteSpace([string]$State.allowUntilUtc)) {
        $UntilLocal = ([datetime]::Parse([string]$State.allowUntilUtc)).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss')
        $Text = "$Text`nAllowed until: $UntilLocal"
    } elseif ($Mode -eq 'Allow') {
        $Text = "$Text`nAllowed until: permanent, until /block"
    }

    return "$Text`nComputer: $env:COMPUTERNAME"
}

function Start-GameBlockerSelfUninstall {
    param(
        [string]$InstallDir,
        [object]$Telegram
    )

    $UninstallScript = Join-Path $InstallDir 'scripts\Uninstall-GameBlocker.ps1'
    if (-not (Test-Path -LiteralPath $UninstallScript)) {
        Send-GameBlockerTelegramReply -Telegram $Telegram -Text "Uninstall script not found: $UninstallScript"
        return
    }

    Publish-GameBlockerEvent -InstallDir $InstallDir -Type 'telegram-uninstall-requested' -Message 'Telegram command requested WorkGameBlocker uninstall.'
    Send-GameBlockerTelegramReply -Telegram $Telegram -Text 'Uninstall started. This removes only WorkGameBlocker task, firewall rules, and files.'

    $PowerShellExe = Join-Path $PSHOME 'powershell.exe'
    $ArgumentList = "-NoProfile -ExecutionPolicy Bypass -File `"$UninstallScript`""
    Start-Process -FilePath $PowerShellExe -ArgumentList $ArgumentList -WindowStyle Hidden
    exit 0
}

function Start-GameBlockerSelfUpdate {
    param(
        [string]$InstallDir,
        [object]$Telegram
    )

    $UpdateScript = Join-Path $InstallDir 'scripts\Update-GameBlocker.ps1'
    if (-not (Test-Path -LiteralPath $UpdateScript)) {
        Send-GameBlockerTelegramReply -Telegram $Telegram -Text "Update script not found: $UpdateScript"
        return
    }

    $Paths = Get-GameBlockerPaths -InstallDir $InstallDir
    if (-not (Test-Path -LiteralPath $Paths.Update)) {
        Send-GameBlockerTelegramReply -Telegram $Telegram -Text 'Self-update is not configured. Reinstall once with WGB_SOURCE_BASE_URL.'
        return
    }

    Publish-GameBlockerEvent -InstallDir $InstallDir -Type 'telegram-update-requested' -Message 'Telegram command requested WorkGameBlocker update.'
    Send-GameBlockerTelegramReply -Telegram $Telegram -Text 'Update started. I will reinstall WorkGameBlocker from the configured GitHub raw URL.'

    $PowerShellExe = Join-Path $PSHOME 'powershell.exe'
    $ArgumentList = "-NoProfile -ExecutionPolicy Bypass -File `"$UpdateScript`" -InstallDir `"$InstallDir`""
    Start-Process -FilePath $PowerShellExe -ArgumentList $ArgumentList -WindowStyle Hidden
    exit 0
}

function Invoke-GameBlockerTelegramCommand {
    param(
        [string]$InstallDir,
        [object]$Telegram,
        [string]$Text
    )

    $Parts = @($Text.Trim() -split '\s+')
    if ($Parts.Count -eq 0 -or [string]::IsNullOrWhiteSpace($Parts[0])) {
        return
    }

    $Command = ([string]$Parts[0]).Split('@')[0].ToLowerInvariant()
    switch ($Command) {
        '/block' {
            Set-GameBlockerStateFile -InstallDir $InstallDir -Mode Block -AllowUntilUtc $null
            Set-GameBlockerFirewallEnabled -Enabled $true | Out-Null
            $Stopped = Stop-GameBlockerBlockedProcesses -InstallDir $InstallDir
            Publish-GameBlockerEvent -InstallDir $InstallDir -Type 'telegram-block' -Message 'Telegram command blocked game access.' -Data @{
                stoppedProcesses = @($Stopped).Count
            }
            Send-GameBlockerTelegramReply -Telegram $Telegram -Text "Blocked game access. Stopped processes: $(@($Stopped).Count)"
        }
        '/allow' {
            $Minutes = 60
            $PermanentAccess = $false
            if ($Parts.Count -ge 2) {
                $AllowArgument = ([string]$Parts[1]).ToLowerInvariant()
                if ($AllowArgument -in @('forever', 'permanent')) {
                    $PermanentAccess = $true
                } else {
                    $ParsedMinutes = 0
                    if ([int]::TryParse([string]$Parts[1], [ref]$ParsedMinutes)) {
                        $Minutes = [Math]::Min(1440, [Math]::Max(1, $ParsedMinutes))
                    }
                }
            }

            if ($PermanentAccess) {
                Set-GameBlockerStateFile -InstallDir $InstallDir -Mode Allow -AllowUntilUtc $null
                Set-GameBlockerFirewallEnabled -Enabled $false | Out-Null
                Publish-GameBlockerEvent -InstallDir $InstallDir -Type 'telegram-allow' -Message 'Telegram command allowed game access permanently until /block.'
                Send-GameBlockerTelegramReply -Telegram $Telegram -Text 'Allowed game access permanently. Use /block to block again.'
            } else {
                $AllowUntilUtc = [datetime]::UtcNow.AddMinutes($Minutes)
                Set-GameBlockerStateFile -InstallDir $InstallDir -Mode Allow -AllowUntilUtc $AllowUntilUtc
                Set-GameBlockerFirewallEnabled -Enabled $false | Out-Null
                Publish-GameBlockerEvent -InstallDir $InstallDir -Type 'telegram-allow' -Message "Telegram command allowed game access for $Minutes minute(s)." -Data @{
                    allowUntilUtc = $AllowUntilUtc.ToString('o')
                }
                Send-GameBlockerTelegramReply -Telegram $Telegram -Text "Allowed game access for $Minutes minute(s). Until: $($AllowUntilUtc.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss'))"
            }
        }
        '/status' {
            Send-GameBlockerTelegramReply -Telegram $Telegram -Text (Get-GameBlockerStatusText -InstallDir $InstallDir)
        }
        '/update' {
            Start-GameBlockerSelfUpdate -InstallDir $InstallDir -Telegram $Telegram
        }
        '/uninstall' {
            Start-GameBlockerSelfUninstall -InstallDir $InstallDir -Telegram $Telegram
        }
        '/remove' {
            Start-GameBlockerSelfUninstall -InstallDir $InstallDir -Telegram $Telegram
        }
        '/help' {
            Send-GameBlockerTelegramReply -Telegram $Telegram -Text "Commands:`n/block`n/allow 60`n/allow forever`n/status`n/update`n/uninstall"
        }
        default {
            Send-GameBlockerTelegramReply -Telegram $Telegram -Text "Unknown command. Use /block, /allow 60, /allow forever, /status, /update, /uninstall."
        }
    }
}

function Apply-GameBlockerTelegramControl {
    param([string]$InstallDir)

    $TelegramMutex = New-Object System.Threading.Mutex($false, 'Global\WorkGameBlockerTelegramControl')
    $TelegramMutexAcquired = $false
    try {
        $TelegramMutexAcquired = $TelegramMutex.WaitOne(0)
        if (-not $TelegramMutexAcquired) {
            return
        }

        $Paths = Get-GameBlockerPaths -InstallDir $InstallDir
        if (-not (Test-Path -LiteralPath $Paths.Telegram)) {
            return
        }

        $Telegram = Get-Content -LiteralPath $Paths.Telegram -Raw | ConvertFrom-Json
        if (-not $Telegram.enabled -or -not $Telegram.controlEnabled) {
            return
        }
        if ([string]::IsNullOrWhiteSpace([string]$Telegram.botToken) -or [string]::IsNullOrWhiteSpace([string]$Telegram.allowedChatId)) {
            return
        }

        $AllowedChatId = [string]$Telegram.allowedChatId
        $PollSeconds = [Math]::Max(2, [int]$Telegram.pollSeconds)
        $Now = [datetime]::UtcNow
        if (($Now - $script:LastTelegramPollUtc).TotalSeconds -lt $PollSeconds) {
            return
        }
        $script:LastTelegramPollUtc = $Now

        $PollingState = Get-GameBlockerTelegramPollingState -InstallDir $InstallDir
        $LastUpdateId = $null
        if (-not [string]::IsNullOrWhiteSpace([string]$PollingState.lastUpdateId)) {
            $LastUpdateId = [int64]$PollingState.lastUpdateId
        }

        try {
            $Uri = "https://api.telegram.org/bot$($Telegram.botToken)/getUpdates"
            $Body = @{
                timeout         = 0
                allowed_updates = '["message"]'
            }
            if ($null -ne $LastUpdateId) {
                $Body.offset = $LastUpdateId + 1
            }

            $Response = Invoke-RestMethod -Method Post -Uri $Uri -Body $Body -TimeoutSec 10
            if (-not $Response.ok) {
                throw 'Telegram getUpdates returned ok=false.'
            }

            $NewestUpdateId = $LastUpdateId
            foreach ($Update in @($Response.result)) {
                $UpdateId = $null
                if ($null -ne $Update.update_id) {
                    $UpdateId = [int64]$Update.update_id
                    if ($null -ne $LastUpdateId -and $UpdateId -le $LastUpdateId) {
                        continue
                    }
                    if ($null -eq $NewestUpdateId -or $UpdateId -gt $NewestUpdateId) {
                        $NewestUpdateId = $UpdateId
                    }

                    Set-GameBlockerTelegramPollingState -InstallDir $InstallDir -LastUpdateId $UpdateId -LastPollUtc $Now.ToString('o') -LastErrorUtc ([string]$PollingState.lastErrorUtc)
                }

                if ($null -eq $Update.message -or [string]::IsNullOrWhiteSpace([string]$Update.message.text)) {
                    continue
                }

                $ChatId = [string]$Update.message.chat.id
                if ($ChatId -ne $AllowedChatId) {
                    Write-GameBlockerLocalEvent -InstallDir $InstallDir -Type 'telegram-unauthorized-chat' -Message 'Ignored Telegram command from non-allowed chat.'
                    continue
                }

                try {
                    Invoke-GameBlockerTelegramCommand -InstallDir $InstallDir -Telegram $Telegram -Text ([string]$Update.message.text)
                } catch {
                    Write-GameBlockerLocalEvent -InstallDir $InstallDir -Type 'telegram-command-error' -Message $_.Exception.Message
                }
            }

            Set-GameBlockerTelegramPollingState -InstallDir $InstallDir -LastUpdateId $NewestUpdateId -LastPollUtc $Now.ToString('o') -LastErrorUtc ([string]$PollingState.lastErrorUtc)
        } catch {
            $CurrentPollingState = Get-GameBlockerTelegramPollingState -InstallDir $InstallDir
            $CurrentUpdateId = if ([string]::IsNullOrWhiteSpace([string]$CurrentPollingState.lastUpdateId)) { $LastUpdateId } else { [int64]$CurrentPollingState.lastUpdateId }
            Set-GameBlockerTelegramPollingState -InstallDir $InstallDir -LastUpdateId $CurrentUpdateId -LastPollUtc $Now.ToString('o') -LastErrorUtc $Now.ToString('o')
            Write-GameBlockerLocalEvent -InstallDir $InstallDir -Type 'telegram-control-error' -Message $_.Exception.Message
        }
    } finally {
        if ($TelegramMutexAcquired) {
            $TelegramMutex.ReleaseMutex()
        }
        $TelegramMutex.Dispose()
    }
}

Publish-GameBlockerEvent -InstallDir $InstallDir -Type 'watcher-started' -Message 'Game process watcher started.'

while ($true) {
    try {
        Apply-GameBlockerTelegramControl -InstallDir $InstallDir
        Apply-GameBlockerRemoteControl -InstallDir $InstallDir

        $Config = Read-GameBlockerConfig -InstallDir $InstallDir
        $State = Get-GameBlockerState -InstallDir $InstallDir
        $Mode = if ([string]::IsNullOrWhiteSpace($State.mode)) { 'Block' } else { [string]$State.mode }

        if ($Mode -eq 'Allow' -and -not [string]::IsNullOrWhiteSpace($State.allowUntilUtc)) {
            $AllowUntilUtc = ([datetime]::Parse([string]$State.allowUntilUtc)).ToUniversalTime()
            if ([datetime]::UtcNow -ge $AllowUntilUtc) {
                Set-GameBlockerStateFile -InstallDir $InstallDir -Mode Block -AllowUntilUtc $null
                Set-GameBlockerFirewallEnabled -Enabled $true | Out-Null
                Publish-GameBlockerEvent -InstallDir $InstallDir -Type 'access-expired' -Message 'Temporary game access expired.'
                $Mode = 'Block'
            }
        }

        if ($Mode -eq 'Block') {
            $Stopped = Stop-GameBlockerBlockedProcesses -InstallDir $InstallDir
            foreach ($Item in $Stopped) {
                $Key = "$($Item.processName)|$($Item.path)"
                if (Test-GameBlockerLogDue -Key $Key -CooldownSeconds ([int]$Config.logCooldownSeconds)) {
                    Publish-GameBlockerEvent -InstallDir $InstallDir -Type 'launch-blocked' -Message 'Blocked configured game process launch attempt.' -Data @{
                        processName = $Item.processName
                        path        = $Item.path
                        id          = $Item.id
                    }
                }
            }
        }
    } catch {
        Write-GameBlockerLocalEvent -InstallDir $InstallDir -Type 'watcher-error' -Message $_.Exception.Message
    }

    $SleepSeconds = 2
    try {
        $SleepSeconds = [Math]::Max(1, [int](Read-GameBlockerConfig -InstallDir $InstallDir).pollSeconds)
    } catch {
        $SleepSeconds = 2
    }

    Start-Sleep -Seconds $SleepSeconds
}

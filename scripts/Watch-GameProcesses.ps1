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

function Get-GameBlockerTelegramPollingState {
    param([string]$InstallDir)

    $Paths = Get-GameBlockerPaths -InstallDir $InstallDir
    if (-not (Test-Path -LiteralPath $Paths.TelegramState)) {
        return [pscustomobject]@{
            lastUpdateId = $null
            lastPollUtc  = $null
            lastErrorUtc = $null
        }
    }

    return Get-Content -LiteralPath $Paths.TelegramState -Raw | ConvertFrom-Json
}

function Set-GameBlockerTelegramPollingState {
    param(
        [string]$InstallDir,
        [Nullable[int64]]$LastUpdateId,
        [string]$LastPollUtc,
        [string]$LastErrorUtc
    )

    $Paths = Get-GameBlockerPaths -InstallDir $InstallDir
    $State = [ordered]@{
        lastUpdateId = if ($LastUpdateId.HasValue) { $LastUpdateId.Value } else { $null }
        lastPollUtc  = $LastPollUtc
        lastErrorUtc = $LastErrorUtc
    }

    $State | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $Paths.TelegramState -Encoding UTF8
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
    }

    return "$Text`nComputer: $env:COMPUTERNAME"
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
            if ($Parts.Count -ge 2) {
                $ParsedMinutes = 0
                if ([int]::TryParse([string]$Parts[1], [ref]$ParsedMinutes)) {
                    $Minutes = [Math]::Min(1440, [Math]::Max(1, $ParsedMinutes))
                }
            }

            $AllowUntilUtc = [datetime]::UtcNow.AddMinutes($Minutes)
            Set-GameBlockerStateFile -InstallDir $InstallDir -Mode Allow -AllowUntilUtc $AllowUntilUtc
            Set-GameBlockerFirewallEnabled -Enabled $false | Out-Null
            Publish-GameBlockerEvent -InstallDir $InstallDir -Type 'telegram-allow' -Message "Telegram command allowed game access for $Minutes minute(s)." -Data @{
                allowUntilUtc = $AllowUntilUtc.ToString('o')
            }
            Send-GameBlockerTelegramReply -Telegram $Telegram -Text "Allowed game access for $Minutes minute(s). Until: $($AllowUntilUtc.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss'))"
        }
        '/status' {
            Send-GameBlockerTelegramReply -Telegram $Telegram -Text (Get-GameBlockerStatusText -InstallDir $InstallDir)
        }
        '/help' {
            Send-GameBlockerTelegramReply -Telegram $Telegram -Text "Commands:`n/block`n/allow 60`n/status"
        }
        default {
            Send-GameBlockerTelegramReply -Telegram $Telegram -Text "Unknown command. Use /block, /allow 60, /status."
        }
    }
}

function Apply-GameBlockerTelegramControl {
    param([string]$InstallDir)

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
            if ($null -ne $Update.update_id) {
                $UpdateId = [int64]$Update.update_id
                if ($null -eq $NewestUpdateId -or $UpdateId -gt $NewestUpdateId) {
                    $NewestUpdateId = $UpdateId
                }
            }

            if ($null -eq $Update.message -or [string]::IsNullOrWhiteSpace([string]$Update.message.text)) {
                continue
            }

            $ChatId = [string]$Update.message.chat.id
            if ($ChatId -ne $AllowedChatId) {
                Write-GameBlockerLocalEvent -InstallDir $InstallDir -Type 'telegram-unauthorized-chat' -Message 'Ignored Telegram command from non-allowed chat.'
                continue
            }

            Invoke-GameBlockerTelegramCommand -InstallDir $InstallDir -Telegram $Telegram -Text ([string]$Update.message.text)
        }

        Set-GameBlockerTelegramPollingState -InstallDir $InstallDir -LastUpdateId $NewestUpdateId -LastPollUtc $Now.ToString('o') -LastErrorUtc ([string]$PollingState.lastErrorUtc)
    } catch {
        Set-GameBlockerTelegramPollingState -InstallDir $InstallDir -LastUpdateId $LastUpdateId -LastPollUtc $Now.ToString('o') -LastErrorUtc $Now.ToString('o')
        Write-GameBlockerLocalEvent -InstallDir $InstallDir -Type 'telegram-control-error' -Message $_.Exception.Message
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

$script:GameBlockerTaskName = 'WorkGameBlocker Watcher'
$script:GameBlockerTaskPath = '\WorkGameBlocker\'
$script:GameBlockerRuleGroup = 'WorkGameBlocker'

function Test-GameBlockerAdmin {
    $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $Principal = New-Object Security.Principal.WindowsPrincipal($Identity)
    return $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-GameBlockerAdmin {
    if (-not (Test-GameBlockerAdmin)) {
        throw 'Run this script from PowerShell as Administrator.'
    }
}

function Get-GameBlockerPaths {
    param([string]$InstallDir)

    [pscustomobject]@{
        Config   = Join-Path $InstallDir 'config\blocked-apps.json'
        State    = Join-Path $InstallDir 'state.json'
        Telegram = Join-Path $InstallDir 'telegram.json'
        TelegramState = Join-Path $InstallDir 'telegram-state.json'
        Update   = Join-Path $InstallDir 'update.json'
        Control  = Join-Path $InstallDir 'control.json'
        ControlState = Join-Path $InstallDir 'remote-control-state.json'
        Logs     = Join-Path $InstallDir 'logs'
    }
}

function Read-GameBlockerConfig {
    param([string]$InstallDir)

    $Paths = Get-GameBlockerPaths -InstallDir $InstallDir
    if (-not (Test-Path -LiteralPath $Paths.Config)) {
        throw "Config file not found: $($Paths.Config)"
    }

    return Get-Content -LiteralPath $Paths.Config -Raw | ConvertFrom-Json
}

function Get-GameBlockerState {
    param([string]$InstallDir)

    $Paths = Get-GameBlockerPaths -InstallDir $InstallDir
    if (-not (Test-Path -LiteralPath $Paths.State)) {
        return [pscustomobject]@{
            mode          = 'Block'
            allowUntilUtc = $null
            updatedAtUtc  = (Get-Date).ToUniversalTime().ToString('o')
        }
    }

    return Get-Content -LiteralPath $Paths.State -Raw | ConvertFrom-Json
}

function Get-GameBlockerControlConfig {
    param([string]$InstallDir)

    $Paths = Get-GameBlockerPaths -InstallDir $InstallDir
    if (-not (Test-Path -LiteralPath $Paths.Control)) {
        return [pscustomobject]@{
            enabled     = $false
            url         = $null
            pollSeconds = 15
            deviceId    = $env:COMPUTERNAME
        }
    }

    return Get-Content -LiteralPath $Paths.Control -Raw | ConvertFrom-Json
}

function Get-GameBlockerRemoteControlState {
    param([string]$InstallDir)

    $Paths = Get-GameBlockerPaths -InstallDir $InstallDir
    if (-not (Test-Path -LiteralPath $Paths.ControlState)) {
        return [pscustomobject]@{
            lastAppliedVersion = $null
            lastPollUtc        = $null
            lastErrorUtc       = $null
        }
    }

    return Get-Content -LiteralPath $Paths.ControlState -Raw | ConvertFrom-Json
}

function Set-GameBlockerRemoteControlState {
    param(
        [string]$InstallDir,
        [string]$LastAppliedVersion,
        [string]$LastPollUtc,
        [string]$LastErrorUtc
    )

    $Paths = Get-GameBlockerPaths -InstallDir $InstallDir
    $State = [ordered]@{
        lastAppliedVersion = $LastAppliedVersion
        lastPollUtc        = $LastPollUtc
        lastErrorUtc       = $LastErrorUtc
    }

    $State | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $Paths.ControlState -Encoding UTF8
}

function Set-GameBlockerStateFile {
    param(
        [string]$InstallDir,
        [ValidateSet('Block', 'Allow')]
        [string]$Mode,
        [Nullable[datetime]]$AllowUntilUtc
    )

    $Paths = Get-GameBlockerPaths -InstallDir $InstallDir
    $State = [ordered]@{
        mode          = $Mode
        allowUntilUtc = if ($AllowUntilUtc.HasValue) { $AllowUntilUtc.Value.ToUniversalTime().ToString('o') } else { $null }
        updatedAtUtc  = (Get-Date).ToUniversalTime().ToString('o')
    }

    $State | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $Paths.State -Encoding UTF8
}

function Expand-GameBlockerPath {
    param([string]$Path)

    $Expanded = [Environment]::ExpandEnvironmentVariables($Path)
    if ($Expanded -like '*`**') {
        return Get-ChildItem -Path $Expanded -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName
    }

    return $Expanded
}

function Write-GameBlockerLocalEvent {
    param(
        [string]$InstallDir,
        [string]$Type,
        [string]$Message,
        [hashtable]$Data = @{}
    )

    $Paths = Get-GameBlockerPaths -InstallDir $InstallDir
    New-Item -ItemType Directory -Force -Path $Paths.Logs | Out-Null

    $Event = [ordered]@{
        timestampUtc = (Get-Date).ToUniversalTime().ToString('o')
        computer     = $env:COMPUTERNAME
        type         = $Type
        message      = $Message
        data         = $Data
    }

    Add-Content -LiteralPath (Join-Path $Paths.Logs 'events.jsonl') -Value ($Event | ConvertTo-Json -Depth 6 -Compress) -Encoding UTF8
}

function Send-GameBlockerTelegram {
    param(
        [string]$InstallDir,
        [string]$Text
    )

    $Paths = Get-GameBlockerPaths -InstallDir $InstallDir
    if (-not (Test-Path -LiteralPath $Paths.Telegram)) {
        return
    }

    try {
        $Telegram = Get-Content -LiteralPath $Paths.Telegram -Raw | ConvertFrom-Json
        if (-not $Telegram.enabled -or [string]::IsNullOrWhiteSpace($Telegram.botToken) -or [string]::IsNullOrWhiteSpace($Telegram.chatId)) {
            return
        }

        $Uri = "https://api.telegram.org/bot$($Telegram.botToken)/sendMessage"
        $Body = @{
            chat_id                  = $Telegram.chatId
            text                     = $Text
            disable_web_page_preview = 'true'
        }

        Invoke-RestMethod -Method Post -Uri $Uri -Body $Body -TimeoutSec 10 | Out-Null
    } catch {
        Write-GameBlockerLocalEvent -InstallDir $InstallDir -Type 'telegram-error' -Message $_.Exception.Message
    }
}

function Send-GameBlockerTelegramDirect {
    param(
        [string]$BotToken,
        [string]$ChatId,
        [string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($BotToken) -or [string]::IsNullOrWhiteSpace($ChatId)) {
        return
    }

    $Uri = "https://api.telegram.org/bot$BotToken/sendMessage"
    $Body = @{
        chat_id                  = $ChatId
        text                     = $Text
        disable_web_page_preview = 'true'
    }

    Invoke-RestMethod -Method Post -Uri $Uri -Body $Body -TimeoutSec 10 | Out-Null
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
        [object]$LastUpdateId,
        [string]$LastPollUtc,
        [string]$LastErrorUtc
    )

    $Paths = Get-GameBlockerPaths -InstallDir $InstallDir
    $StoredUpdateId = $null
    if ($null -ne $LastUpdateId -and -not [string]::IsNullOrWhiteSpace([string]$LastUpdateId)) {
        $StoredUpdateId = [int64]$LastUpdateId
    }

    $State = [ordered]@{
        lastUpdateId = $StoredUpdateId
        lastPollUtc  = $LastPollUtc
        lastErrorUtc = $LastErrorUtc
    }

    $State | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $Paths.TelegramState -Encoding UTF8
}

function Initialize-GameBlockerTelegramOffset {
    param([string]$InstallDir)

    $Paths = Get-GameBlockerPaths -InstallDir $InstallDir
    if (-not (Test-Path -LiteralPath $Paths.Telegram)) {
        return $null
    }

    $Telegram = Get-Content -LiteralPath $Paths.Telegram -Raw | ConvertFrom-Json
    if (-not $Telegram.enabled -or -not $Telegram.controlEnabled) {
        return $null
    }
    if ([string]::IsNullOrWhiteSpace([string]$Telegram.botToken)) {
        return $null
    }

    try {
        $Uri = "https://api.telegram.org/bot$($Telegram.botToken)/getUpdates"
        $Response = Invoke-RestMethod -Method Post -Uri $Uri -Body @{
            timeout         = 0
            allowed_updates = '["message"]'
        } -TimeoutSec 10

        $LastUpdateId = $null
        foreach ($Update in @($Response.result)) {
            if ($null -ne $Update.update_id) {
                $UpdateId = [int64]$Update.update_id
                if ($null -eq $LastUpdateId -or $UpdateId -gt $LastUpdateId) {
                    $LastUpdateId = $UpdateId
                }
            }
        }

        Set-GameBlockerTelegramPollingState -InstallDir $InstallDir -LastUpdateId $LastUpdateId -LastPollUtc ([datetime]::UtcNow).ToString('o') -LastErrorUtc $null
        return $LastUpdateId
    } catch {
        Write-GameBlockerLocalEvent -InstallDir $InstallDir -Type 'telegram-offset-init-error' -Message $_.Exception.Message
        return $null
    }
}

function Publish-GameBlockerEvent {
    param(
        [string]$InstallDir,
        [string]$Type,
        [string]$Message,
        [hashtable]$Data = @{}
    )

    Write-GameBlockerLocalEvent -InstallDir $InstallDir -Type $Type -Message $Message -Data $Data

    $Lines = @(
        '[WorkGameBlocker]',
        "Event: $Type",
        "Message: $Message",
        "Computer: $env:COMPUTERNAME",
        "Time UTC: $((Get-Date).ToUniversalTime().ToString('o'))"
    )

    if ($Data.ContainsKey('processName')) {
        $Lines += "Process: $($Data.processName)"
    }
    if ($Data.ContainsKey('path') -and -not [string]::IsNullOrWhiteSpace($Data.path)) {
        $Lines += "Path: $($Data.path)"
    }

    Send-GameBlockerTelegram -InstallDir $InstallDir -Text ($Lines -join "`n")
}

function Sync-GameBlockerFirewallRules {
    param(
        [string]$InstallDir,
        [bool]$Enabled = $true
    )

    $Config = Read-GameBlockerConfig -InstallDir $InstallDir
    Remove-NetFirewallRule -Group $script:GameBlockerRuleGroup -ErrorAction SilentlyContinue

    $RuleEnabled = if ($Enabled) { 'True' } else { 'False' }
    $Created = 0

    foreach ($Pattern in $Config.blockedProgramPaths) {
        foreach ($ProgramPath in @(Expand-GameBlockerPath -Path $Pattern)) {
            if (-not [string]::IsNullOrWhiteSpace($ProgramPath) -and (Test-Path -LiteralPath $ProgramPath)) {
                $Name = "WorkGameBlocker Block $([IO.Path]::GetFileName($ProgramPath))"
                New-NetFirewallRule -DisplayName $Name -Group $script:GameBlockerRuleGroup -Direction Outbound -Program $ProgramPath -Action Block -Profile Any -Enabled $RuleEnabled | Out-Null
                $Created++
            }
        }
    }

    return $Created
}

function Set-GameBlockerFirewallEnabled {
    param([bool]$Enabled)

    $Rules = Get-NetFirewallRule -Group $script:GameBlockerRuleGroup -ErrorAction SilentlyContinue
    if (-not $Rules) {
        return 0
    }

    if ($Enabled) {
        $Rules | Enable-NetFirewallRule | Out-Null
    } else {
        $Rules | Disable-NetFirewallRule | Out-Null
    }

    return @($Rules).Count
}

function Stop-GameBlockerBlockedProcesses {
    param([string]$InstallDir)

    $Config = Read-GameBlockerConfig -InstallDir $InstallDir
    $Stopped = New-Object System.Collections.Generic.List[hashtable]

    foreach ($ProcessName in $Config.blockedProcesses) {
        $Name = [IO.Path]::GetFileNameWithoutExtension([string]$ProcessName)
        $Processes = @(Get-Process -Name $Name -ErrorAction SilentlyContinue)
        foreach ($Process in $Processes) {
            $Path = $null
            try {
                $Path = $Process.Path
            } catch {
                $Path = $null
            }

            try {
                Stop-Process -Id $Process.Id -Force -ErrorAction Stop
                $Stopped.Add([ordered]@{
                    processName = $Process.ProcessName
                    id          = $Process.Id
                    path        = $Path
                })
            } catch {
                $Stopped.Add([ordered]@{
                    processName = $Process.ProcessName
                    id          = $Process.Id
                    path        = $Path
                    error       = $_.Exception.Message
                })
            }
        }
    }

    return $Stopped
}

function Stop-GameBlockerExistingWatchers {
    param([string]$InstallDir)

    $Stopped = 0
    $InstallDirPattern = [regex]::Escape($InstallDir)
    $Processes = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
            $_.ProcessId -ne $PID -and
            $_.CommandLine -match 'Watch-GameProcesses\.ps1' -and
            ($_.CommandLine -match $InstallDirPattern -or $_.CommandLine -match 'WorkGameBlocker')
        })

    foreach ($Process in $Processes) {
        try {
            Stop-Process -Id $Process.ProcessId -Force -ErrorAction Stop
            $Stopped++
        } catch {
        }
    }

    return $Stopped
}

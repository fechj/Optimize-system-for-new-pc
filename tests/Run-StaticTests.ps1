$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent $PSScriptRoot
$Failures = New-Object System.Collections.Generic.List[string]

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        $Failures.Add($Message)
    }
}

function Read-Text {
    param([string]$RelativePath)

    $Path = Join-Path $Root $RelativePath
    if (-not (Test-Path -LiteralPath $Path)) {
        return ''
    }

    return Get-Content -LiteralPath $Path -Raw
}

$RequiredFiles = @(
    'README.md',
    'Bootstrap-GameBlocker.ps1',
    'config\blocked-apps.json',
    'scripts\GameBlocker.Common.ps1',
    'scripts\Install-GameBlocker.ps1',
    'scripts\Set-GameBlockerState.ps1',
    'scripts\Update-GameBlocker.ps1',
    'scripts\Uninstall-GameBlocker.ps1',
    'scripts\Watch-GameProcesses.ps1'
)

foreach ($RelativePath in $RequiredFiles) {
    Assert-True (Test-Path -LiteralPath (Join-Path $Root $RelativePath)) "Missing required file: $RelativePath"
}

$ConfigPath = Join-Path $Root 'config\blocked-apps.json'
if (Test-Path -LiteralPath $ConfigPath) {
    $Config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    Assert-True ($Config.blockedProcesses.Count -ge 8) 'Default config should include common game and launcher processes.'
    Assert-True ($Config.blockedProcesses -contains 'steam') 'Default config should block steam.'
    Assert-True ($Config.blockedProcesses -contains 'dota2') 'Default config should block dota2.'
}

$Install = Read-Text 'scripts\Install-GameBlocker.ps1'
$State = Read-Text 'scripts\Set-GameBlockerState.ps1'
$Update = Read-Text 'scripts\Update-GameBlocker.ps1'
$Watcher = Read-Text 'scripts\Watch-GameProcesses.ps1'
$Uninstall = Read-Text 'scripts\Uninstall-GameBlocker.ps1'
$Common = Read-Text 'scripts\GameBlocker.Common.ps1'
$Bootstrap = Read-Text 'Bootstrap-GameBlocker.ps1'
$AllScripts = "$Bootstrap`n$Common`n$Install`n$State`n$Update`n$Watcher`n$Uninstall"

Assert-True ($Bootstrap -match 'Install-WorkGameBlocker') 'Bootstrap should expose an install function for irm | iex usage.'
Assert-True ($Bootstrap -match 'SourceBaseUrl') 'Bootstrap should download package files from a raw source base URL.'
Assert-True ($Install -match 'Register-ScheduledTask') 'Installer should register a visible Windows scheduled task.'
Assert-True ($Install -match 'Stop-ScheduledTask') 'Installer should stop the previous scheduled task before replacing it.'
Assert-True ($AllScripts -match 'Stop-GameBlockerExistingWatchers') 'Installer should stop old watcher processes before starting a new watcher.'
Assert-True ($Bootstrap -match 'SourceBaseUrl' -and $Install -match 'SourceBaseUrl') 'Bootstrap should pass SourceBaseUrl into the installer.'
Assert-True ($Install -match 'update\.json') 'Installer should store update source settings locally.'
Assert-True ($AllScripts -match 'New-NetFirewallRule') 'Package should create firewall rules for known installed paths.'
Assert-True ($Install -match 'ControlUrl') 'Installer should accept a remote control URL.'
Assert-True ($State -match 'Block|Allow') 'State script should support block and allow modes.'
Assert-True ($AllScripts -match 'Stop-Process') 'Package should stop blocked game processes.'
Assert-True ($AllScripts -match 'api\.telegram\.org') 'Package should send Telegram notifications.'
Assert-True ($AllScripts -match 'getUpdates') 'Package should support Telegram bot polling control.'
Assert-True ($Install -match 'EnableTelegramControl') 'Installer should require an explicit Telegram control switch.'
Assert-True ($Watcher -match 'Apply-GameBlockerTelegramControl') 'Watcher should apply Telegram Block/Allow/Status commands.'
Assert-True ($Watcher -match 'AllowedChatId') 'Telegram control should restrict commands to the configured chat id.'
Assert-True ($Watcher -match '/block' -and $Watcher -match '/allow' -and $Watcher -match '/status') 'Telegram control should support /block, /allow, and /status.'
Assert-True ($Watcher -match 'forever' -and $Watcher -match 'permanent') 'Telegram control should support /allow forever permanent access.'
Assert-True ($Watcher -match '/uninstall' -and $Watcher -match 'Start-GameBlockerSelfUninstall') 'Telegram control should support scoped /uninstall for this tool.'
Assert-True ($Watcher -match 'Uninstall-GameBlocker\.ps1' -and $Watcher -match 'Start-Process' -and $Watcher -match 'WindowStyle Hidden') 'Telegram uninstall should launch the bundled uninstaller in a hidden process.'
Assert-True ($Watcher -match '/update' -and $Watcher -match 'Start-GameBlockerSelfUpdate') 'Telegram control should support /update self-update.'
Assert-True ($Update -match 'Update-GameBlocker' -and $Update -match 'Invoke-WebRequest' -and $Update -match 'Install-GameBlocker\.ps1') 'Updater should download package files and run the bundled installer.'
Assert-True ($Watcher -match 'Global\\WorkGameBlockerTelegramControl') 'Telegram polling should use a named mutex to avoid duplicate processing from parallel watchers.'
Assert-True ($Watcher -match 'Set-GameBlockerTelegramPollingState -InstallDir \$InstallDir -LastUpdateId \$UpdateId') 'Telegram polling should acknowledge each update before executing its command.'
Assert-True ($AllScripts -match 'Initialize-GameBlockerTelegramOffset') 'Installer should initialize Telegram offset so old commands are not replayed after reinstall.'
Assert-True ($Watcher -match 'blockedProcesses') 'Watcher should only act on configured blocked process names.'
Assert-True ($Watcher -match 'Invoke-RestMethod') 'Watcher should poll a remote control URL when configured.'
Assert-True ($Watcher -match 'Apply-GameBlockerRemoteControl') 'Watcher should apply remote Block/Allow control.'
Assert-True ($Uninstall -match 'Unregister-ScheduledTask') 'Uninstaller should remove the scheduled task.'

$ForbiddenPatterns = @(
    'Get-Clipboard',
    'SetWindowsHookEx',
    'GetAsyncKeyState',
    'FromScreen',
    'CopyFromScreen',
    'Documents\\',
    'Desktop\\',
    'Downloads\\',
    'Get-Credential',
    'ConvertFrom-SecureString'
)

foreach ($Pattern in $ForbiddenPatterns) {
    Assert-True ($AllScripts -notmatch [regex]::Escape($Pattern)) "Forbidden personal-data collection pattern found: $Pattern"
}

if ($Failures.Count -gt 0) {
    $Failures | ForEach-Object { Write-Error $_ -ErrorAction Continue }
    exit 1
}

Write-Host 'Static tests passed.'

[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:ProgramData 'WorkGameBlocker')
)

$ErrorActionPreference = 'Stop'
. (Join-Path $InstallDir 'scripts\GameBlocker.Common.ps1')

Assert-GameBlockerAdmin

$Paths = Get-GameBlockerPaths -InstallDir $InstallDir
if (-not (Test-Path -LiteralPath $Paths.Update)) {
    throw "Update config not found: $($Paths.Update)"
}

$UpdateConfig = Get-Content -LiteralPath $Paths.Update -Raw | ConvertFrom-Json
if (-not $UpdateConfig.enabled -or [string]::IsNullOrWhiteSpace([string]$UpdateConfig.sourceBaseUrl)) {
    throw 'Self-update is not enabled because SourceBaseUrl was not stored during installation.'
}

$Telegram = $null
if (Test-Path -LiteralPath $Paths.Telegram) {
    $Telegram = Get-Content -LiteralPath $Paths.Telegram -Raw | ConvertFrom-Json
}

$Control = $null
if (Test-Path -LiteralPath $Paths.Control) {
    $Control = Get-Content -LiteralPath $Paths.Control -Raw | ConvertFrom-Json
}

$SourceBaseUrl = ([string]$UpdateConfig.sourceBaseUrl).TrimEnd('/')
$BootstrapRoot = Join-Path $env:TEMP 'WorkGameBlockerUpdate'
$Files = @(
    'config/blocked-apps.json',
    'scripts/GameBlocker.Common.ps1',
    'scripts/Install-GameBlocker.ps1',
    'scripts/Set-GameBlockerState.ps1',
    'scripts/Update-GameBlocker.ps1',
    'scripts/Watch-GameProcesses.ps1',
    'scripts/Uninstall-GameBlocker.ps1'
)

foreach ($RelativePath in $Files) {
    $Destination = Join-Path $BootstrapRoot ($RelativePath -replace '/', '\')
    $DestinationDir = Split-Path -Parent $Destination
    New-Item -ItemType Directory -Force -Path $DestinationDir | Out-Null

    $Uri = "$SourceBaseUrl/$RelativePath"
    Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $Destination
}

$InstallScript = Join-Path $BootstrapRoot 'scripts\Install-GameBlocker.ps1'
$InstallArgs = @{
    InstallDir    = $InstallDir
    SourceBaseUrl = $SourceBaseUrl
    DeviceId      = $env:COMPUTERNAME
}

if ($Telegram -and $Telegram.enabled -and -not [string]::IsNullOrWhiteSpace([string]$Telegram.botToken) -and -not [string]::IsNullOrWhiteSpace([string]$Telegram.chatId)) {
    $InstallArgs.TelegramBotToken = [string]$Telegram.botToken
    $InstallArgs.TelegramChatId = [string]$Telegram.chatId
    if ($Telegram.controlEnabled) {
        $InstallArgs.EnableTelegramControl = $true
    }
    if ($Telegram.PSObject.Properties['pollSeconds']) {
        $InstallArgs.TelegramPollSeconds = [int]$Telegram.pollSeconds
    }
} else {
    $InstallArgs.NoTelegram = $true
}

if ($Control -and $Control.enabled -and -not [string]::IsNullOrWhiteSpace([string]$Control.url)) {
    $InstallArgs.ControlUrl = [string]$Control.url
    if ($Control.PSObject.Properties['pollSeconds']) {
        $InstallArgs.ControlPollSeconds = [int]$Control.pollSeconds
    }
    if ($Control.PSObject.Properties['deviceId'] -and -not [string]::IsNullOrWhiteSpace([string]$Control.deviceId)) {
        $InstallArgs.DeviceId = [string]$Control.deviceId
    }
}

& $InstallScript @InstallArgs

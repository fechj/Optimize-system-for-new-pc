[CmdletBinding()]
param(
    [string]$SourceBaseUrl = $env:WGB_SOURCE_BASE_URL,
    [string]$TelegramBotToken = $env:WGB_BOT_TOKEN,
    [string]$TelegramChatId = $env:WGB_CHAT_ID,
    [string]$ControlUrl = $env:WGB_CONTROL_URL,
    [string]$DeviceId = $env:WGB_DEVICE_ID,
    [string]$InstallDir = $env:WGB_INSTALL_DIR,
    [string]$EnableTelegramControl = $env:WGB_ENABLE_TELEGRAM_CONTROL,
    [switch]$NoAutoInstall
)

$ErrorActionPreference = 'Stop'

function Test-WorkGameBlockerAdmin {
    $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $Principal = New-Object Security.Principal.WindowsPrincipal($Identity)
    return $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Install-WorkGameBlocker {
    [CmdletBinding()]
    param(
        [string]$SourceBaseUrl = $env:WGB_SOURCE_BASE_URL,
        [string]$TelegramBotToken = $env:WGB_BOT_TOKEN,
        [string]$TelegramChatId = $env:WGB_CHAT_ID,
        [string]$ControlUrl = $env:WGB_CONTROL_URL,
        [string]$DeviceId = $env:WGB_DEVICE_ID,
        [string]$InstallDir = $env:WGB_INSTALL_DIR,
        [string]$EnableTelegramControl = $env:WGB_ENABLE_TELEGRAM_CONTROL
    )

    if (-not (Test-WorkGameBlockerAdmin)) {
        throw 'Run PowerShell as Administrator before installing WorkGameBlocker.'
    }

    if ([string]::IsNullOrWhiteSpace($SourceBaseUrl)) {
        $SourceBaseUrl = 'https://raw.githubusercontent.com/YOUR_USER/YOUR_REPO/main'
    }
    $SourceBaseUrl = $SourceBaseUrl.TrimEnd('/')

    if ([string]::IsNullOrWhiteSpace($DeviceId)) {
        $DeviceId = $env:COMPUTERNAME
    }

    if ([string]::IsNullOrWhiteSpace($InstallDir)) {
        $InstallDir = Join-Path $env:ProgramData 'WorkGameBlocker'
    }

    $BootstrapRoot = Join-Path $env:TEMP 'WorkGameBlockerBootstrap'
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
        InstallDir     = $InstallDir
        DeviceId       = $DeviceId
        SourceBaseUrl  = $SourceBaseUrl
    }

    if (-not [string]::IsNullOrWhiteSpace($TelegramBotToken) -and -not [string]::IsNullOrWhiteSpace($TelegramChatId)) {
        $InstallArgs.TelegramBotToken = $TelegramBotToken
        $InstallArgs.TelegramChatId = $TelegramChatId
        if ($EnableTelegramControl -eq '1' -or $EnableTelegramControl -eq 'true') {
            $InstallArgs.EnableTelegramControl = $true
        }
    } else {
        $InstallArgs.NoTelegram = $true
    }

    if (-not [string]::IsNullOrWhiteSpace($ControlUrl)) {
        $InstallArgs.ControlUrl = $ControlUrl
    }

    & $InstallScript @InstallArgs
}

if (-not $NoAutoInstall -and $env:WGB_NO_AUTO_INSTALL -ne '1') {
    Install-WorkGameBlocker -SourceBaseUrl $SourceBaseUrl -TelegramBotToken $TelegramBotToken -TelegramChatId $TelegramChatId -ControlUrl $ControlUrl -DeviceId $DeviceId -InstallDir $InstallDir -EnableTelegramControl $EnableTelegramControl
}

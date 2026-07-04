# WorkGameBlocker

PowerShell-пакет для рабочего Windows-ПК: блокирует Steam, Dota 2 и другие игровые лаунчеры из конфигурации, а в Telegram отправляет только служебные события по этому инструменту.

Он не читает личные файлы, не снимает скриншоты, не пишет клавиатуру и не собирает историю браузера. Логи ограничены событиями: установка, смена режима, истечение временного доступа и попытка запуска процесса из `config\blocked-apps.json`.

## Важные условия

- Установку нужно запускать от имени администратора.
- Если сотрудник остается локальным администратором, он технически сможет удалить задачу, правила firewall или сам пакет.
- Для нормального контроля сделайте сотруднику обычную Windows-учетку без прав администратора, а себе оставьте отдельную admin-учетку.
- Telegram bot token хранится локально в `C:\ProgramData\WorkGameBlocker\telegram.json`; папка ограничивается для `SYSTEM` и `Administrators`.

## Установка

Создайте Telegram-бота через BotFather и получите `chat_id`, затем на рабочем ПК запустите PowerShell от имени администратора:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\scripts\Install-GameBlocker.ps1 -TelegramBotToken "123456:ABC..." -TelegramChatId "123456789" -EnableTelegramControl
```

## Установка одной командой через GitHub raw

Загрузите содержимое этой папки в приватный или публичный GitHub-репозиторий. После этого raw base URL будет выглядеть примерно так:

```text
https://raw.githubusercontent.com/YOUR_USER/YOUR_REPO/main
```

Команда для сотрудника, PowerShell от имени администратора:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "$env:WGB_SOURCE_BASE_URL='https://raw.githubusercontent.com/YOUR_USER/YOUR_REPO/main'; $env:WGB_BOT_TOKEN='123456:ABC...'; $env:WGB_CHAT_ID='123456789'; $env:WGB_ENABLE_TELEGRAM_CONTROL='1'; irm $env:WGB_SOURCE_BASE_URL/Bootstrap-GameBlocker.ps1 | iex"
```

Если Telegram не нужен:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "$env:WGB_SOURCE_BASE_URL='https://raw.githubusercontent.com/YOUR_USER/YOUR_REPO/main'; $env:WGB_CONTROL_URL='https://raw.githubusercontent.com/YOUR_USER/YOUR_REPO/main/control.json'; irm $env:WGB_SOURCE_BASE_URL/Bootstrap-GameBlocker.ps1 | iex"
```

Не публикуйте Telegram bot token в GitHub. Он должен быть только в команде установки или вводиться вами вручную на ПК.

## Управление через Telegram-бота

Если установка была запущена с `WGB_ENABLE_TELEGRAM_CONTROL='1'` или `-EnableTelegramControl`, watcher будет читать команды через Telegram Bot API `getUpdates`.

Принимаются команды только из `TelegramChatId`, указанного при установке:

```text
/block
/allow 60
/status
/help
```

`/allow 60` разрешает игры на 60 минут. Можно указать от 1 до 1440 минут. Когда время закончится, watcher сам вернет блокировку.

Важно: это не remote shell. Бот не выполняет произвольный PowerShell, а принимает только эти четыре команды.

Без Telegram:

```powershell
.\scripts\Install-GameBlocker.ps1 -NoTelegram
```

После установки создается видимая задача Windows:

```text
\WorkGameBlocker\WorkGameBlocker Watcher
```

## Управление доступом

Заблокировать сразу:

```powershell
C:\ProgramData\WorkGameBlocker\scripts\Set-GameBlockerState.ps1 -Mode Block
```

Разрешить игры на 60 минут:

```powershell
C:\ProgramData\WorkGameBlocker\scripts\Set-GameBlockerState.ps1 -Mode Allow -Minutes 60
```

Когда время истечет, watcher сам вернет режим `Block` и отправит событие.

## Удаленное управление через JSON

При установке с `-ControlUrl` watcher периодически читает JSON по HTTPS. Он не выполняет удаленный PowerShell-код, а принимает только режим `Block` или `Allow`.

Простой `control.json`:

```json
{
  "mode": "Block",
  "version": "2026-07-04T12:00:00Z"
}
```

Разрешить игры до конкретного UTC-времени:

```json
{
  "mode": "Allow",
  "allowUntilUtc": "2026-07-04T18:00:00Z",
  "version": "2026-07-04T17:00:00Z"
}
```

Для нескольких ПК можно использовать `default` и `devices`:

```json
{
  "default": {
    "mode": "Block",
    "version": "2026-07-04T12:00:00Z"
  },
  "devices": {
    "EMPLOYEE-PC": {
      "mode": "Allow",
      "allowUntilUtc": "2026-07-04T18:00:00Z",
      "version": "2026-07-04T17:00:00Z"
    }
  }
}
```

Каждый раз, когда меняете команду, меняйте `version`, например на текущее UTC-время. Это защищает от повторного применения старой команды.

## Что блокируется

Список находится в:

```text
C:\ProgramData\WorkGameBlocker\config\blocked-apps.json
```

По умолчанию там есть Steam, `steamwebhelper`, `dota2`, `cs2`, Epic Games, Battle.net, Riot, EA, Ubisoft, GOG, Minecraft и Roblox. Можно добавить имя процесса без `.exe`, например:

```json
"SomeGameProcess"
```

После изменения конфига перезапустите задачу или ПК.

## Логи

Локальный журнал:

```text
C:\ProgramData\WorkGameBlocker\logs\events.jsonl
```

Telegram-события содержат только тип события, имя ПК, UTC-время, имя заблокированного процесса и путь к exe, если Windows его отдала.

## Удаление

PowerShell от имени администратора:

```powershell
C:\ProgramData\WorkGameBlocker\scripts\Uninstall-GameBlocker.ps1
```

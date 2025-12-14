# Telegram Schedule Bot (ІФНТУНГ)

Telegram-бот для перегляду розкладу академічних груп ІФНТУНГ.  
Дані беруться з сайту деканату (`timetable.cgi`) і кешуються у локальних JSON-файлах.

## Можливості
- Вибір групи (пошук за частиною назви)
- **Сьогодні** / **Розклад (Пн–Нд)** / **Залишок дня**
- Команди: `/start`, `/menu`, `/mygroup`, `/group <запит>`, `/today`, `/tomorrow`, `/day <день>`, `/week`
- Оновлення розкладу **на вимогу** (коли користувач запитує розклад)

## Вимоги
- Ruby 3.x
- Bundler
- Доступ до інтернету

## Встановлення
```bash
bundle install
```

## Налаштування токена
Створи файл `.env` у корені проєкту:
```env
TELEGRAM_BOT_TOKEN=YOUR_TOKEN_HERE
```

> ⚠️ Безпека: не публікуй токен. Якщо токен вже «засвітився», перегенеруй його в @BotFather і заміни у `.env`.

## Запуск
```bash
ruby bot.rb
# або
bundle exec ruby bot.rb
```

## Дані, які зберігає бот
- `user_groups.json` — chat_id -> group_name  
- `group_ids.json` — group_name -> site_group_id  
- `schedule.json` — кеш розкладу (group_name -> date -> lessons)

## Запуск як systemd-сервіс (приклад)
Файл: `/etc/systemd/system/telegram_schedule_bot.service`
```ini
[Unit]
Description=Telegram Schedule Bot
After=network.target

[Service]
Type=simple
WorkingDirectory=/home/<user>/telegram_schedule_bo
Environment=TELEGRAM_BOT_TOKEN=YOUR_TOKEN_HERE
ExecStart=/bin/bash -lc 'bundle exec ruby bot.rb'
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
```

Далі:
```bash
sudo systemctl daemon-reload
sudo systemctl enable telegram_schedule_bot
sudo systemctl start telegram_schedule_bot
sudo systemctl status telegram_schedule_bot
```

## Підтримка/діагностика
- Логи systemd: `journalctl -u telegram_schedule_bot -f`
- Примусово оновити групу: `/update_group <назва>`
- Заповнити `group_ids.json`: `/sync_group_ids`

## Роль «викладач»
У репозиторії є `user_roles.json` (заготовка), але інтерфейс викладача ще не інтегрований у `bot.rb`.

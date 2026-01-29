#!/bin/bash
set -e

INSTALL_DIR="/opt/n8n-install"

### Проверка прав
if (( EUID != 0 )); then
  echo "❗ Скрипт должен быть запущен от root"
  exit 1
fi

clear
echo "🌐 Автоматическая установка n8n"
echo "----------------------------------------"

### 1. Ввод переменных
read -p "🌐 Введите домен для n8n (например: n8n.example.com): " DOMAIN
read -p "📧 Введите email для SSL-сертификата Let's Encrypt: " EMAIL
read -p "🤖 Введите Telegram Bot Token: " TG_BOT_TOKEN
read -p "👤 Введите Telegram User ID (для уведомлений): " TG_USER_ID
read -s -p "🔐 Введите пароль для базы данных Postgres: " POSTGRES_PASSWORD
echo
read -p "🗝️  Введите ключ шифрования для n8n (Enter для генерации): " N8N_ENCRYPTION_KEY

if [ -z "$N8N_ENCRYPTION_KEY" ]; then
  N8N_ENCRYPTION_KEY=$(openssl rand -hex 32)
  echo "✅ Сгенерирован ключ шифрования:"
  echo "$N8N_ENCRYPTION_KEY"
  echo "⬆️ СОХРАНИТЕ ЕГО. БЕЗ НЕГО ДАННЫЕ НЕ ВОССТАНОВИТЬ."
fi

### Proxy (опционально)
echo
read -p "🌍 Использовать proxy? (y/N): " USE_PROXY

HTTP_PROXY=""
HTTPS_PROXY=""
NO_PROXY="localhost,127.0.0.1,::1,postgres,redis,traefik,n8n-app,n8n-worker"

if [[ "$USE_PROXY" =~ ^[Yy]$ ]]; then
  read -p "Вставь прокси (формат http://user:pass@ip:port): " PROXY_INPUT
  if [[ "$PROXY_INPUT" != http* ]]; then
     HTTP_PROXY="http://$PROXY_INPUT"
     HTTPS_PROXY="http://$PROXY_INPUT"
  else
     HTTP_PROXY="$PROXY_INPUT"
     HTTPS_PROXY="$PROXY_INPUT"
  fi
fi

### 2. Docker
echo "📦 Проверка Docker..."
if ! command -v docker &>/dev/null; then
  curl -fsSL https://get.docker.com | sh
fi

### 3. Клонирование проекта
if [[ -d "$INSTALL_DIR" ]]; then
  echo "⚠️ Папка установки уже существует. Пересобираем..."
  # Если переустанавливаем поверх - почистим старый акме файл на всякий случай, чтобы права обновить
  rm -f "$INSTALL_DIR/letsencrypt/acme.json"
fi

if [ ! -d "$INSTALL_DIR" ]; then
  echo "📥 Клонируем проект с GitHub..."
  git clone https://github.com/DreamerBY/n8n-beget-install.git "$INSTALL_DIR"
fi

cd "$INSTALL_DIR"

# Если папка была, сделаем pull свежих изменений
git pull origin main

### 4. Генерация .env
DOCKER_GID=$(getent group docker | cut -d: -f3 || echo 999)

cat > ".env" <<EOF
# === Domain / SSL ===
DOMAIN=${DOMAIN}
EMAIL=${EMAIL}

# === Database ===
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}

# === n8n core ===
N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
GENERIC_TIMEZONE=Asia/Yekaterinburg
NODE_ENV=production
N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=true
N8N_RUNNERS_ENABLED=true
N8N_VERSION=1.121.2
DOCKER_GID=${DOCKER_GID}

# === Telegram ===
TG_BOT_TOKEN=${TG_BOT_TOKEN}
TG_USER_ID=${TG_USER_ID}

# === Proxy ===
PROXY_URL=${HTTP_PROXY}
NO_PROXY=${NO_PROXY}
EOF

chmod 600 .env

### 5. Директории
mkdir -p data logs backups letsencrypt shims traefik_dynamic
touch logs/backup.log

# ВАЖНО: Создаем файл сертификатов заранее с правильными правами
# Traefik не умеет сам выставлять 600 при создании через Docker volume bind
touch letsencrypt/acme.json
chmod 600 letsencrypt/acme.json

### 6. shims (обертки)
cat > shims/ffmpeg <<'EOF'
#!/usr/bin/env bash
exec /usr/bin/ffmpeg "$@"
EOF

cat > shims/yt-dlp <<'EOF'
#!/usr/bin/env bash
exec /usr/bin/yt-dlp "$@"
EOF

cat > shims/python <<'EOF'
#!/usr/bin/env bash
exec /usr/bin/python3 "$@"
EOF

cat > shims/python3 <<'EOF'
#!/usr/bin/env bash
exec /usr/bin/python3 "$@"
EOF

chmod +x shims/*

### 7. Запуск
echo "🚀 Запуск docker compose..."
docker compose down --remove-orphans || true
docker compose up -d --build

echo "⏳ Ждем 20 секунд инициализации n8n..."
sleep 20
echo "🔄 Перезагрузка Traefik для подхвата сертификатов..."
docker compose restart n8n-traefik

### 8. Telegram notify
if [ ! -z "$TG_BOT_TOKEN" ]; then
  curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
    -d chat_id="${TG_USER_ID}" \
    -d text="✅ Установка n8n (1.121.2) завершена. Домен: https://${DOMAIN}"
fi

### 9. Итог
echo
docker ps --format "table {{.Names}}\t{{.Status}}"
echo
echo "🎉 Готово! Открой: https://${DOMAIN}"

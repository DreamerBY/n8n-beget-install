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
read -p "🌐 Введите домен (без http, например: n8n.site.com): " DOMAIN
read -p "📧 Email для сертификатов (Let's Encrypt): " EMAIL
read -p "🤖 Telegram Bot Token: " TG_BOT_TOKEN
read -p "👤 Telegram User ID: " TG_USER_ID
read -s -p "🔐 Пароль для Postgres: " POSTGRES_PASSWORD
echo
read -p "🗝️  Ключ шифрования n8n (Enter = сгенерировать): " N8N_ENCRYPTION_KEY

if [ -z "$N8N_ENCRYPTION_KEY" ]; then
  N8N_ENCRYPTION_KEY=$(openssl rand -hex 32)
  echo "✅ Сгенерирован ключ: $N8N_ENCRYPTION_KEY"
fi

### PROXY (Исправленная логика)
echo
echo "🌍 Настройка Proxy (если не нужно - просто нажми Enter)"
read -p "👉 Введите прокси (формат http://user:pass@ip:port): " PROXY_INPUT

HTTP_PROXY=""
HTTPS_PROXY=""
NO_PROXY="localhost,127.0.0.1,::1,postgres,redis,traefik,n8n-app,n8n-worker"

if [ ! -z "$PROXY_INPUT" ]; then
  # Если пользователь забыл http://, добавим его
  if [[ "$PROXY_INPUT" != http* ]]; then
     HTTP_PROXY="http://$PROXY_INPUT"
     HTTPS_PROXY="http://$PROXY_INPUT"
  else
     HTTP_PROXY="$PROXY_INPUT"
     HTTPS_PROXY="$PROXY_INPUT"
  fi
  echo "✅ Прокси будет использован: $HTTP_PROXY"
else
  echo "⏩ Прокси не указан, идем дальше."
fi

### 2. Docker
if ! command -v docker &>/dev/null; then
  echo "📦 Установка Docker..."
  curl -fsSL https://get.docker.com | sh
fi

### 3. Клонирование
if [ -d "$INSTALL_DIR" ]; then
  echo "⚠️ Папка установки существует. Обновляем скрипты..."
  rm -f "$INSTALL_DIR/letsencrypt/acme.json" # Чистим старые права на всякий случай
else
  echo "📥 Клонируем репозиторий..."
  git clone https://github.com/DreamerBY/n8n-beget-install.git "$INSTALL_DIR"
fi

cd "$INSTALL_DIR"
git pull origin main

### 4. Генерация .env
DOCKER_GID=$(getent group docker | cut -d: -f3 || echo 999)

cat > ".env" <<EOF
DOMAIN=${DOMAIN}
EMAIL=${EMAIL}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
GENERIC_TIMEZONE=Asia/Yekaterinburg
NODE_ENV=production
N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=true
N8N_RUNNERS_ENABLED=true
N8N_VERSION=1.121.2
DOCKER_GID=${DOCKER_GID}
TG_BOT_TOKEN=${TG_BOT_TOKEN}
TG_USER_ID=${TG_USER_ID}
PROXY_URL=${HTTP_PROXY}
HTTP_PROXY=${HTTP_PROXY}
HTTPS_PROXY=${HTTPS_PROXY}
NO_PROXY=${NO_PROXY}
EOF

chmod 600 .env

### 5. Папки
mkdir -p data logs backups letsencrypt shims traefik_dynamic
touch logs/backup.log

### 6. Обертки (shims)
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
echo "🚀 Запуск контейнеров..."
docker compose down --remove-orphans || true
docker volume rm n8n-install_traefik_letsencrypt 2>/dev/null || true # Удаляем старый том сертификатов для чистоты
docker compose up -d --build

### 8. Уведомление
if [ ! -z "$TG_BOT_TOKEN" ]; then
  curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
    -d chat_id="${TG_USER_ID}" \
    -d text="✅ Установка n8n завершена: https://${DOMAIN}"
fi

echo "🎉 Готово! https://${DOMAIN}"

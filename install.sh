#!/bin/bash
set -e

DB_USER="bench_user"
DB_NAME="material_bench"
DB_PASS=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32)

APP_NAME="material_bench_api"
APP_DIR="/opt/$APP_NAME"
PYTHON_BIN="python3"
PIP_BIN="pip"

if [ "$EUID" -ne 0 ]; then
  echo "❌ Этот скрипт нужно запускать от имени root (sudo)."
  echo "   Пример: sudo $0"
  exit 1
fi

echo "🚀 Начинаем полный bootstrap для $APP_NAME..."

echo "📦 Установка необходимых пакетов..."
apt update -qq
apt install -y "$PYTHON_BIN"-venv "$PYTHON_BIN"-pip postgresql postgresql-client build-essential gunicorn || { echo "❌ Ошибка установки пакетов."; exit 1; }

echo "🔍 Проверка, запущен ли PostgreSQL..."
systemctl start postgresql 2>/dev/null || true
systemctl enable postgresql

echo "🧩 Проверка/создание пользователя '$DB_USER'..."
if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'" | grep -q 1; then
    echo "✅ Пользователь '$DB_USER' уже существует."
    echo "🔑 Обновляю пароль для пользователя '$DB_USER'..."
    sudo -u postgres psql -c "ALTER USER $DB_USER WITH PASSWORD '$DB_PASS';"
else
    echo "👤 Создаю пользователя '$DB_USER' с новым случайным паролем..."
    sudo -u postgres psql -c "CREATE USER $DB_USER WITH PASSWORD '$DB_PASS';"
fi

echo "🧱 Проверка/создание базы данных '$DB_NAME'..."
if sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'" | grep -q 1; then
    echo "✅ База данных '$DB_NAME' уже существует."
else
    echo "📦 Создаю базу данных '$DB_NAME' владельцем '$DB_USER'..."
    sudo -u postgres createdb -O "$DB_USER" "$DB_NAME"
fi

echo "⚙️ Настройка среды приложения..."

mkdir -p "$APP_DIR"
"$PYTHON_BIN" -m venv "$APP_DIR/venv"
source "$APP_DIR/venv/bin/activate"

echo "fastapi" > /tmp/requirements.txt
echo "uvicorn" >> /tmp/requirements.txt
echo "asyncpg" >> /tmp/requirements.txt
"$PIP_BIN" install -r /tmp/requirements.txt
rm /tmp/requirements.txt
deactivate

echo "📄 Создание systemd сервиса и .env файла с паролем..."

cat << EOF > "$APP_DIR/.env"
DB_USER=$DB_USER
DB_PASS=$DB_PASS
DB_NAME=$DB_NAME
DB_HOST=localhost
EOF
chmod 600 "$APP_DIR/.env"

cat << EOF > /etc/systemd/system/$APP_NAME.service
[Unit]
Description=$APP_NAME FastAPI Service
After=network.target postgresql.service

[Service]
User=www-data
Group=www-data
WorkingDirectory=$APP_DIR
EnvironmentFile=$APP_DIR/.env
ExecStart=$APP_DIR/venv/bin/gunicorn __main__:app --bind 0.0.0.0:8010
Restart=always
ExecStartPre=/usr/bin/git -C $APP_DIR reset --hard
ExecStartPre=/usr/bin/git -C $APP_DIR pull

[Install]
WantedBy=multi-user.target
EOF

echo "▶️ Запуск и включение сервиса $APP_NAME..."
systemctl daemon-reload
systemctl enable "$APP_NAME.service"
systemctl start "$APP_NAME.service"
systemctl status "$APP_NAME.service" --no-pager || true

echo
echo "✅ ВСЁ ГОТОВО!"
echo "   Приложение работает как systemd сервис на порту 8010."
echo "   Сгенерированный пароль БД: $DB_PASS"
echo "   Учетные данные сохранены в $APP_DIR/.env"
echo
echo "🚨 СЛЕДУЮЩИЙ ШАГ: Настройка Nginx (вручную):"
echo "   1. Создайте прокси-конфигурацию Nginx для перенаправления с 80/443 на localhost:8010."
echo "   2. Обеспечьте TLS-шифрование (Let's Encrypt)."
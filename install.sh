#!/bin/bash
set -e

GIT_REPO_URL="${GIT_REPO_URL:-https://github.com/Komaru-dude/Material-Bench-backend.git}"
APP_DIR="${APP_DIR:-/opt/material_bench_api}"
APP_NAME="${APP_NAME:-material_bench_api}"
DB_USER="${DB_USER:-bench_user}"
DB_NAME="${DB_NAME:-material_bench}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
VENV_PYTHON="$APP_DIR/venv/bin/python3"
DB_PASS="${DB_PASS:-$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32)}"
FALLBACK_REQUIREMENTS=("fastapi" "uvicorn" "asyncpg" "gunicorn")

if [ "$(id -u)" -ne 0 ]; then
  echo "Этот скрипт должен быть запущен от имени root (sudo)."
  exit 1
fi

echo "=== Установка зависимостей системы ==="
apt update -qq
DEBIAN_FRONTEND=noninteractive apt install -y python3-venv python3-pip postgresql postgresql-client build-essential git openssl

echo "=== Настройка приложения ==="
mkdir -p "$APP_DIR"
chown root:root "$APP_DIR"
chmod 755 "$APP_DIR"

if [ ! -d "$APP_DIR/.git" ]; then
  if [ -z "$(ls -A "$APP_DIR")" ]; then
    echo "Клонирование $GIT_REPO_URL в $APP_DIR ..."
    git clone --depth 1 "$GIT_REPO_URL" "$APP_DIR"
  else
    echo "$APP_DIR не пуста, но не является git репозиторием — клонирование во временную директорию и копирование."
    TMPDIR=$(mktemp -d)
    git clone --depth 1 "$GIT_REPO_URL" "$TMPDIR/repo"
    cp -a "$TMPDIR/repo/." "$APP_DIR/"
    rm -rf "$TMPDIR"
    chown -R root:root "$APP_DIR"
  fi
else
  echo "Репозиторий найден в $APP_DIR — обновление."
  git -C "$APP_DIR" fetch --all --prune
  git -C "$APP_DIR" reset --hard origin/HEAD
  git -C "$APP_DIR" pull --ff-only
fi

echo "=== Настройка виртуального окружения Python ==="
if [ ! -d "$APP_DIR/venv" ]; then
  "$PYTHON_BIN" -m venv "$APP_DIR/venv"
fi

if [ ! -f "$VENV_PYTHON" ]; then
  echo "Ошибка: Python в виртуальном окружении не найден!"
  exit 1
fi

echo "Установка/обновление pip и setuptools..."
"$VENV_PYTHON" -m pip install --upgrade pip setuptools

echo "=== Установка зависимостей Python ==="
if [ -f "$APP_DIR/requirements.txt" ]; then
  echo "Установка requirements из $APP_DIR/requirements.txt"
  "$VENV_PYTHON" -m pip install -r "$APP_DIR/requirements.txt"
else
  echo "requirements.txt не найден — установка базовых пакетов"
  for pkg in "${FALLBACK_REQUIREMENTS[@]}"; do
    "$VENV_PYTHON" -m pip install "$pkg"
  done
fi

echo "=== Настройка PostgreSQL ==="
systemctl start postgresql || true
systemctl enable postgresql || true

echo "Настройка пользователя и базы данных..."
if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'" | grep -q 1; then
  echo "Пользователь $DB_USER уже существует — обновление пароля"
  sudo -u postgres psql -c "ALTER USER \"$DB_USER\" WITH ENCRYPTED PASSWORD '$DB_PASS';"
else
  echo "Создание пользователя $DB_USER"
  sudo -u postgres psql -c "CREATE USER \"$DB_USER\" WITH ENCRYPTED PASSWORD '$DB_PASS';"
fi

if sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'" | grep -q 1; then
  echo "База данных $DB_NAME уже существует."
else
  echo "Создание базы данных $DB_NAME"
  sudo -u postgres createdb -O "$DB_USER" "$DB_NAME"
fi

echo "=== Создание .env файла ==="
cat > "$APP_DIR/.env" <<EOF
DB_USER=$DB_USER
DB_PASS=$DB_PASS
DB_NAME=$DB_NAME
DB_HOST=localhost
EOF
chmod 600 "$APP_DIR/.env"

echo "=== Настройка systemd службы ==="
SERVICE_PATH="/etc/systemd/system/$APP_NAME.service"
cat > "$SERVICE_PATH" <<EOF
[Unit]
Description=$APP_NAME FastAPI Service
After=network.target postgresql.service
Wants=postgresql.service

[Service]
User=www-data
Group=www-data
WorkingDirectory=$APP_DIR
EnvironmentFile=$APP_DIR/.env
ExecStart=$APP_DIR/venv/bin/gunicorn __main__:app --workers 4 --worker-class uvicorn.workers.UvicornWorker --bind 0.0.0.0:8000
Restart=on-failure
RestartSec=5
TimeoutStartSec=30

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "$APP_NAME.service"
systemctl restart "$APP_NAME.service"

echo "=== Проверка статуса службы ==="
sleep 3
systemctl --no-pager status "$APP_NAME.service" -l

echo "=== Последние логи службы ==="
journalctl -u "$APP_NAME.service" -n 20 --no-pager || true

echo "=== Установка завершена! ==="
echo "Приложение установлено в: $APP_DIR"
echo "Служба: $APP_NAME.service"
echo "База данных: $DB_NAME, пользователь: $DB_USER"
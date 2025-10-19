#!/bin/bash
set -e

GIT_REPO_URL="${GIT_REPO_URL:-https://github.com/Komaru-dude/Material-Bench-backend.git}"
APP_DIR="${APP_DIR:-/opt/material_bench_api}"
APP_NAME="${APP_NAME:-material_bench_api}"
DB_USER="${DB_USER:-bench_user}"
DB_NAME="${DB_NAME:-material_bench}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
DB_PASS="${DB_PASS:-$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32)}"
FALLBACK_REQUIREMENTS=("fastapi" "uvicorn" "asyncpg" "gunicorn")

if [ "$(id -u)" -ne 0 ]; then
  echo "Этот скрипт должен быть запущен от имени root (sudo)."
  exit 1
fi

mkdir -p "$APP_DIR"
chown root:root "$APP_DIR"
chmod 755 "$APP_DIR"

if [ ! -d "$APP_DIR/.git" ]; then
  if [ -z "$(ls -A "$APP_DIR")" ]; then
    echo "Cloning $GIT_REPO_URL into $APP_DIR ..."
    git clone --depth 1 "$GIT_REPO_URL" "$APP_DIR"
  else
    echo "$APP_DIR not empty and .git missing — cloning to temp and merging."
    TMPDIR=$(mktemp -d)
    git clone --depth 1 "$GIT_REPO_URL" "$TMPDIR/repo"
    cp -a "$TMPDIR/repo/." "$APP_DIR/"
    rm -rf "$TMPDIR"
    chown -R root:root "$APP_DIR"
  fi
else
  echo "Repository present in $APP_DIR — updating."
  git -C "$APP_DIR" fetch --all --prune
  git -C "$APP_DIR" reset --hard origin/HEAD || true
  git -C "$APP_DIR" pull --ff-only || true
fi

apt update -qq
DEBIAN_FRONTEND=noninteractive apt install -y python3-venv python3-pip postgresql postgresql-client build-essential git openssl

if [ ! -d "$APP_DIR/venv" ]; then
  "$PYTHON_BIN" -m venv "$APP_DIR/venv"
fi

PIP_CMD="$APP_DIR/venv/bin/python -m pip"
"$PIP_CMD" install --upgrade pip setuptools

if [ -f "$APP_DIR/requirements.txt" ]; then
  echo "Installing requirements from $APP_DIR/requirements.txt"
  "$PIP_CMD" install -r "$APP_DIR/requirements.txt"
else
  echo "requirements.txt not found — installing fallback packages"
  for pkg in "${FALLBACK_REQUIREMENTS[@]}"; do
    "$PIP_CMD" install "$pkg"
  done
fi

systemctl start postgresql || true
systemctl enable postgresql || true

if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'" | grep -q 1; then
  sudo -u postgres psql -c "ALTER USER \"$DB_USER\" WITH ENCRYPTED PASSWORD '$DB_PASS';"
else
  sudo -u postgres psql -c "CREATE USER \"$DB_USER\" WITH ENCRYPTED PASSWORD '$DB_PASS';"
fi

if sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'" | grep -q 1; then
  echo "Database $DB_NAME already exists."
else
  sudo -u postgres createdb -O "$DB_USER" "$DB_NAME"
fi

cat > "$APP_DIR/.env" <<EOF
DB_USER=$DB_USER
DB_PASS=$DB_PASS
DB_NAME=$DB_NAME
DB_HOST=localhost
EOF
chmod 600 "$APP_DIR/.env"

chown -R www-data:www-data "$APP_DIR" || true

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

ExecStartPre=/bin/bash -c '[ -d "$APP_DIR/.git" ] && /usr/bin/git -C "$APP_DIR" reset --hard || true'
ExecStartPre=/bin/bash -c '[ -d "$APP_DIR/.git" ] && /usr/bin/git -C "$APP_DIR" pull || true'

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

echo "=== systemctl status ==="
systemctl --no-pager status "$APP_NAME.service" -l
echo "=== journalctl ==="
journalctl -u "$APP_NAME.service" -n 50 --no-pager || true

echo "Done."

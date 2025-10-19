#!/bin/bash
set -e

GIT_REPO_URL="https://github.com/Komaru-dude/Material-Bench-backend.git" # Укажите свой если делаете форк
DB_USER="bench_user"
DB_NAME="material_bench"
DB_PASS=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32)
APP_NAME="material_bench_api"
APP_DIR="$(pwd)" 
PYTHON_BIN="python3" 
PIP_BIN="pip"         

"$PYTHON_BIN" -m venv "$APP_DIR/venv"
source "$APP_DIR/venv/bin/activate"
echo "fastapi" > /tmp/requirements.txt
echo "uvicorn" >> /tmp/requirements.txt
echo "asyncpg" >> /tmp/requirements.txt
echo "gunicorn" >> /tmp/requirements.txt 
"$PIP_BIN" install -r /tmp/requirements.txt
rm /tmp/requirements.txt
deactivate

if [ "$EUID" -ne 0 ]; then
  exit 1
fi

apt update -qq
apt install -y "$PYTHON_BIN"-venv "$PYTHON_BIN"-pip postgresql postgresql-client build-essential gunicorn git openssl
systemctl start postgresql 2>/dev/null || true 
systemctl enable postgresql

if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'" | grep -q 1; then
    sudo -u postgres psql -c "ALTER USER $DB_USER WITH PASSWORD '$DB_PASS';"
else
    sudo -u postgres psql -c "CREATE USER $DB_USER WITH PASSWORD '$DB_PASS';"
fi

if sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'" | grep -q 1; then
    :
else
    sudo -u postgres createdb -O "$DB_USER" "$DB_NAME"
fi

cat << EOF > "$APP_DIR/.env"
DB_USER=$DB_USER
DB_PASS=$DB_PASS
DB_NAME=$DB_NAME
DB_HOST=localhost
EOF
chmod 600 "$APP_DIR/.env" 
chown -R www-data:www-data "$APP_DIR" || true

cat << EOF > /etc/systemd/system/$APP_NAME.service
[Unit]
Description=$APP_NAME FastAPI Service
After=network.target postgresql.service

[Service]
User=www-data 
Group=www-data
WorkingDirectory=$APP_DIR
EnvironmentFile=$APP_DIR/.env 

ExecStartPre=/usr/bin/git -C $APP_DIR reset --hard
ExecStartPre=/usr/bin/git -C $APP_DIR pull

ExecStart=$APP_DIR/venv/bin/gunicorn __main__:app --workers 4 --worker-class uvicorn.workers.UvicornWorker --bind 0.0.0.0:8000
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "$APP_NAME.service"
systemctl start "$APP_NAME.service"
systemctl status "$APP_NAME.service" --no-pager
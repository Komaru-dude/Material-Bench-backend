#!/bin/bash
set -e

APP_DIR="material-bench-backend"
SERVICE_NAME="material-bench-backend"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
GIT_REPO="https://github.com/Komaru-dude/Material-Bench-backend"
APP_USER="materialbench"

if [ "$EUID" -ne 0 ]; then
    echo "⚠️  Скрипт требует root-доступ. Перезапустите с sudo:"
    echo "sudo $0"
    exit 1
fi

echo "🔧 Установка FastAPI приложения ${SERVICE_NAME}"

if id "${APP_USER}" &>/dev/null; then
    echo "👤 Пользователь ${APP_USER} уже существует."
else
    echo "👤 Создаю системного пользователя ${APP_USER}..."
    useradd -r -m -d /opt/${APP_DIR} -s /usr/sbin/nologin ${APP_USER}
    echo "✅ Пользователь ${APP_USER} создан."
fi

apt update -y
apt install -y python3 python3-venv git openssl

cd /opt

if [ -d "${APP_DIR}" ]; then
    echo "♻️  Директория ${APP_DIR} уже существует, удаляю..."
    rm -rf "${APP_DIR}"
fi

echo "⬇️  Клонирую репозиторий ${GIT_REPO}..."
git clone "${GIT_REPO}" "${APP_DIR}"
cd "${APP_DIR}"
chown -R ${APP_USER}:${APP_USER} .

echo "🐍 Создаю виртуальное окружение..."
sudo -u ${APP_USER} python3 -m venv venv

echo "📦 Устанавливаю зависимости..."
sudo -u ${APP_USER} bash -c "source venv/bin/activate && \
    if [ -f requirements.txt ]; then pip install -r requirements.txt; \
    else pip install 'fastapi[all]' uvicorn asyncpg python-dotenv; fi"

DB_PASS=$(openssl rand -base64 12)
cat <<EOF > .env.example
DB_USER=app_user
DB_PASS=${DB_PASS}
DB_NAME=mb_db
DB_HOST=localhost
EOF
chown ${APP_USER}:${APP_USER} .env.example
echo "✅ Файл .env.example создан."

FULL_APP_PATH="/opt/${APP_DIR}"
FULL_VENV_PATH="${FULL_APP_PATH}/venv/bin"

cat <<EOF > "start_server.sh"
#!/bin/bash
cd "${FULL_APP_PATH}"
git fetch origin main
git reset --hard origin/main
source venv/bin/activate
exec "${FULL_VENV_PATH}/uvicorn" app.__main__:app --host 0.0.0.0 --port 8000 --workers 2
EOF

chmod +x "start_server.sh"
chown ${APP_USER}:${APP_USER} start_server.sh
echo "✅ Скрипт start_server.sh создан."

cat <<EOF > "${SERVICE_FILE}"
[Unit]
Description=${SERVICE_NAME} FastAPI Application
After=network.target postgresql.service

[Service]
User=${APP_USER}
Group=${APP_USER}
WorkingDirectory=${FULL_APP_PATH}
ExecStart=/bin/bash ${FULL_APP_PATH}/start_server.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

echo "✅ Unit-файл создан: ${SERVICE_FILE}"

systemctl daemon-reload
systemctl enable ${SERVICE_NAME}.service

echo ""
echo "-------------------------------------------"
echo "✅ Установка завершена!"
echo "-------------------------------------------"
echo ""
echo "📄 Дальнейшие шаги:"
echo "1. Скопируйте '.env.example' в '.env' и настройте доступ к БД:"
echo "   sudo -u ${APP_USER} cp /opt/${APP_DIR}/.env.example /opt/${APP_DIR}/.env"
echo "   sudo -u ${APP_USER} nano /opt/${APP_DIR}/.env"
echo ""
echo "2. Запустите сервис:"
echo "   sudo systemctl start ${SERVICE_NAME}.service"
echo ""
echo "3. Проверьте статус:"
echo "   sudo systemctl status ${SERVICE_NAME}.service"
echo ""
echo "4. Приложение будет доступно по адресу:"
echo "   http://<ваш_IP>:8000"

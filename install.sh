#!/bin/bash

set -e

APP_DIR="material-bench-backend"
SERVICE_NAME="material-bench-backend"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
GIT_REPO="https://github.com/Komaru-dude/Material-Bench-backend"
USER_TO_RUN=$(whoami)

echo "Установка будет выполнена для пользователя: ${USER_TO_RUN}"

apt update -qq
apt install -y python3 python3-venv git openssl
apt upgrade -y python3 python3-venv

echo "Клонирую репозиторий ${GIT_REPO}..."
if [ -d "$APP_DIR" ]; then
    echo "Директория ${APP_DIR} уже существует. Удаляю старую и клонирую заново..."
    rm -rf "$APP_DIR"
fi

git clone "${GIT_REPO}"
echo "Клонирование завершено."
cd "${APP_DIR}"

echo "Создаю виртуальное окружение в директории 'venv'..."
python3 -m venv venv
echo "Виртуальное окружение создано."

echo "Активирую окружение и устанавливаю зависимости..."
source venv/bin/activate

if [ -f "requirements.txt" ]; then
    pip install -r requirements.txt
else
    pip install "fastapi[all]" uvicorn asyncpg python-dotenv
fi
echo "Все зависимости успешно установлены."

DB_PASS=$(openssl rand -base64 12)

echo "Создаю пример файла .env.example..."
cat <<EOF > .env.example
DB_USER=app_user
DB_PASS=${DB_PASS}
DB_NAME=mb_db
DB_HOST=localhost
EOF
echo "Файл .env.example создан."

echo "Создаю вспомогательный скрипт запуска 'start_server.sh'..."

FULL_APP_PATH=$(pwd)
FULL_VENV_PATH="${FULL_APP_PATH}/venv/bin"

cat <<EOF > "start_server.sh"
#!/bin/bash
git fetch
git reset --hard origin/main
source venv/bin/activate
exec "${FULL_VENV_PATH}/uvicorn" app.__main__:app --host 0.0.0.0 --port 8000 --workers 2
EOF
chmod +x "start_server.sh"
echo "Скрипт 'start_server.sh' создан."

echo "Создаю systemd Unit-файл ${SERVICE_FILE}..."

cat <<EOF > "${SERVICE_FILE}"
[Unit]
Description=${SERVICE_NAME} FastAPI Application
After=network.target postgresql.service

[Service]
User=${USER_TO_RUN}
Group=${USER_TO_RUN}
WorkingDirectory=${FULL_APP_PATH}
ExecStart=/bin/bash ${FULL_APP_PATH}/start_server.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

echo "Systemd Unit-файл создан и помещен в ${SERVICE_FILE}."

echo ""
echo "-------------------------------------------"
echo "✅ Установка завершена!"
echo "-------------------------------------------"
echo ""

echo "Следующие шаги для завершения развертывания:"
echo "1. Скопируйте '.env.example' в файл с именем '.env' в директории **${APP_DIR}**:"
echo "   **cp ${APP_DIR}/.env.example ${APP_DIR}/.env**"
echo ""
echo "2. Отредактируйте файл **${APP_DIR}/.env** и укажите реальные данные для подключения к БД."
echo ""
echo "3. Для активации и запуска systemd-сервиса выполните (требуются права root/sudo):"
echo "   **sudo systemctl daemon-reload**"
echo "   **sudo systemctl enable ${SERVICE_NAME}.service**"
echo "   **sudo systemctl start ${SERVICE_NAME}.service**"
echo ""
echo "4. Проверьте статус сервиса:"
echo "   **sudo systemctl status ${SERVICE_NAME}.service**"
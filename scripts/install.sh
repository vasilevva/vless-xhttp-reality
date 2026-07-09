#!/bin/bash
set -e                                                      # Выход из скрипта при любой ошибке
set -o pipefail                                             # Ошибки в конвейерах (pipes) тоже прерывают выполнение

# ==============================================================================
# ЦВЕТОВОЕ ОФОРМЛЕНИЕ ВЫВОДА
# ==============================================================================
RED='\033[0;31m'                                            # Красный цвет для ошибок
GREEN='\033[0;32m'                                          # Зелёный цвет для успешных сообщений
YELLOW='\033[1;33m'                                         # Жёлтый цвет для предупреждений
BLUE='\033[0;34m'                                           # Синий цвет для информации
NC='\033[0m'                                                # Сброс цвета (No Color)

# ==============================================================================
# ФУНКЦИИ ЛОГИРОВАНИЯ
# ==============================================================================
log_info() {
  echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
  echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
  echo -e "${RED}[ERROR]${NC} $1"
  exit 1
}

log_debug() {
  echo -e "${BLUE}[DEBUG]${NC} $1"
}

# ==============================================================================
# ФУНКЦИЯ: ГЕНЕРАЦИЯ СЛУЧАЙНОГО БЕЗОПАСНОГО ПАРОЛЯ
# ==============================================================================
generate_secure_password() {
  local length=${1:-32}
  openssl rand -base64 48 | tr -dc 'A-Za-z0-9!@#$%^&*' | head -c "$length"
}

# ==============================================================================
# ФУНКЦИЯ: ГЕНЕРАЦИЯ СЛУЧАЙНОГО ПУТИ ДЛЯ ПАНЕЛИ
# ==============================================================================
generate_random_path() {
  local part1=$(openssl rand -hex 4)
  local part2=$(openssl rand -hex 4)
  echo "/${part1}${part2}/"
}

# ==============================================================================
# ФУНКЦИЯ: ГЕНЕРАЦИЯ СЛУЧАЙНОГО ПОРТА
# ==============================================================================
generate_random_port() {
  shuf -i 10000-65000 -n 1
}

# ==============================================================================
# ФУНКЦИЯ: СОЗДАНИЕ ХЭША ПАРОЛЯ ДЛЯ PORTAINER
# ==============================================================================
create_portainer_password_hash() {
  local password=$1
  htpasswd -nbB admin "$password" | cut -d ":" -f 2
}

# ==============================================================================
# ФУНКЦИЯ: ПРОВЕРКА СИСТЕМНЫХ ТРЕБОВАНИЙ
# ==============================================================================
check_requirements() {
  log_info "Проверка системных требований..."
  
  if ! command -v curl &> /dev/null; then
    log_warn "curl не найден. Устанавливаем..."
    apt-get update -qq
    apt-get install -y curl
  fi
  
  if ! command -v docker &> /dev/null; then
    log_warn "Docker не найден. Устанавливаем..."
    curl -fsSL https://get.docker.com | sh
    systemctl enable docker
    systemctl start docker
  fi
  
  if ! docker compose version &> /dev/null; then
    log_warn "Docker Compose не найден. Устанавливаем..."
    apt-get update -qq
    apt-get install -y docker-compose-plugin
  fi
  
  if ! command -v openssl &> /dev/null; then
    log_warn "openssl не найден. Устанавливаем..."
    apt-get install -y openssl
  fi
  
  if ! command -v htpasswd &> /dev/null; then
    log_warn "apache2-utils не найден. Устанавливаем..."
    apt-get install -y apache2-utils
  fi
  
  if [ "$EUID" -ne 0 ]; then
    log_error "Скрипт должен быть запущен с правами root (sudo)"
  fi
  
  log_info "✓ Все требования выполнены"
}

# ==============================================================================
# ФУНКЦИЯ: ГЕНЕРАЦИЯ КОНФИГУРАЦИИ
# ==============================================================================
generate_config() {
  log_info "Генерация конфигурации..."
  
  log_debug "Создание директорий..."
  mkdir -p data/{3x-ui,cert,logs,portainer}
  mkdir -p backups
  
  chmod 700 data
  chmod 600 data/cert
  
  if [ -f .env ]; then
    log_debug "Загрузка существующих переменных из .env"
    source .env
  fi
  
  # Генерация UUID
  if [ -z "$UUID" ]; then
    UUID=$(cat /proc/sys/kernel/random/uuid)
    export UUID
    log_info "Сгенерирован UUID: $UUID"
  fi
  
  # Генерация ключей Reality
  if [ -z "$REALITY_PRIVATE_KEY" ]; then
    log_info "Генерация ключей Reality..."
    
    # Запускаем контейнер Xray для генерации ключей x25519
    # Перенаправляем stderr в /dev/null, чтобы скрыть предупреждения Docker
    KEYS=$(docker run --rm ghcr.io/xtls/xray-core:latest x25519 2>/dev/null)
    
    if [ -z "$KEYS" ]; then
      log_error "Не удалось получить вывод от xray x25519. Проверьте работу Docker."
    fi

    # Извлекаем приватный ключ
    REALITY_PRIVATE_KEY=$(echo "$KEYS" | awk '/PrivateKey:/ {print $2}')
    
    # Извлекаем публичный ключ (поддержка всех форматов вывода Xray)
    # Формат 1 (новый, v25.3.6+): Password: <key>
    # Формат 2 (средний): Password (PublicKey): <key>
    # Формат 3 (старый): PublicKey: <key>
    REALITY_PUBLIC_KEY=$(echo "$KEYS" | awk '
      /^PublicKey:/ {print $2; exit}
      /^Password \(PublicKey\):/ {print $3; exit}
      /^Password:/ {print $2; exit}
    ')

    # ЕДИНСТВЕННАЯ проверка, что ключи успешно сгенерированы
    if [ -z "$REALITY_PRIVATE_KEY" ] || [ -z "$REALITY_PUBLIC_KEY" ]; then
      log_error "Не удалось сгенерировать ключи Reality."
      log_error "Вывод команды x25519 был:"
      echo "$KEYS"
      exit 1
    fi
    
    export REALITY_PRIVATE_KEY
    export REALITY_PUBLIC_KEY
    log_info "✓ Ключи Reality сгенерированы"
  fi
  
  # Генерация Short ID
  if [ -z "$REALITY_SHORT_ID" ]; then
    REALITY_SHORT_ID=$(openssl rand -hex 8)
    export REALITY_SHORT_ID
    log_info "Сгенерирован Short ID: $REALITY_SHORT_ID"
  fi
  
  # Генерация порта панели
  if [ -z "$PANEL_PORT" ] || [ "$PANEL_PORT" = "58492" ]; then
    PANEL_PORT=$(generate_random_port)
    export PANEL_PORT
    log_info "Сгенерирован случайный порт панели: $PANEL_PORT"
  fi
  
  # Генерация пути панели
  if [ -z "$PANEL_PATH" ] || [ "$PANEL_PATH" = "/x7k9m2p4q8w1n5b3/" ]; then
    PANEL_PATH=$(generate_random_path)
    export PANEL_PATH
    log_info "Сгенерирован скрытый путь панели: $PANEL_PATH"
  fi
  
  # Генерация пароля панели
  if [ "$PANEL_PASSWORD" = "Kx9#mP2\$vL5nQ8@wR4" ] || [ -z "$PANEL_PASSWORD" ]; then
    PANEL_PASSWORD=$(generate_secure_password 24)
    export PANEL_PASSWORD
    log_info "Сгенерирован безопасный пароль панели"
  fi
  
  # Генерация пароля Portainer
  if [ -z "$PORTAINER_PASSWORD" ]; then
    PORTAINER_PASSWORD=$(generate_secure_password 16)
    export PORTAINER_PASSWORD
    log_info "Сгенерирован пароль Portainer"
  fi
  
  # Генерация хэша пароля Portainer
  if [ -z "$PORTAINER_HASHED_PASSWORD" ]; then
    log_info "Создание хэша пароля Portainer..."
    PORTAINER_HASHED_PASSWORD=$(create_portainer_password_hash "$PORTAINER_PASSWORD")
    export PORTAINER_HASHED_PASSWORD
    log_info "✓ Хэш пароля Portainer создан"
  fi
  
  # Создание файла .env
  log_debug "Сохранение конфигурации в .env..."
  cat > .env << EOF
# ==============================================================================
# АВТОМАТИЧЕСКИ СГЕНЕРИРОВАННАЯ КОНФИГУРАЦИЯ
# Дата генерации: $(date '+%Y-%m-%d %H:%M:%S')
# ==============================================================================

# Имя проекта Docker Compose
COMPOSE_PROJECT_NAME=vless-reality

# Настройки панели 3X-UI (УСИЛЕННАЯ БЕЗОПАСНОСТЬ)
PANEL_PORT=${PANEL_PORT}
PANEL_PATH=${PANEL_PATH}
PANEL_USERNAME=${PANEL_USERNAME:-superadmin_x9k2}
PANEL_PASSWORD=${PANEL_PASSWORD}

# Настройки Xray
XRAY_LOG_LEVEL=warning
VLESS_PORT=443
UUID=${UUID}

# Настройки Reality
REALITY_DEST=www.microsoft.com:443
REALITY_SNI=www.microsoft.com
REALITY_PRIVATE_KEY=${REALITY_PRIVATE_KEY}
REALITY_PUBLIC_KEY=${REALITY_PUBLIC_KEY}
REALITY_SHORT_ID=${REALITY_SHORT_ID}

# Безопасность
FAIL2BAN_ENABLED=true
FAIL2BAN_MAX_RETRY=3
FAIL2BAN_BANTIME=86400
FAIL2BAN_FINDTIME=600

# Portainer (СКРЫТЫЙ ДОСТУП)
PORTAINER_PORT=9000
PORTAINER_USERNAME=${PORTAINER_USERNAME:-admin}
PORTAINER_PASSWORD=${PORTAINER_PASSWORD}
PORTAINER_HASHED_PASSWORD=${PORTAINER_HASHED_PASSWORD}

# Системные настройки
TZ=Europe/Moscow
EOF
  
  chmod 600 .env
  log_info "✓ Конфигурация сохранена в .env (права: 600)"
}

# ==============================================================================
# ФУНКЦИЯ: ВКЛЮЧЕНИЕ IP-ФОРВАРДИНГА НА УРОВНЕ ХОСТА
# ==============================================================================
setup_ip_forwarding() {
  log_info "Настройка IP-форвардинга на уровне хоста..."
  
  CURRENT_VALUE=$(sysctl -n net.ipv4.ip_forward)
  if [ "$CURRENT_VALUE" = "1" ]; then
    log_info "✓ IP-форвардинг уже включён"
  else
    log_info "Включение IP-форвардинга..."
    sysctl -w net.ipv4.ip_forward=1
    log_info "✓ IP-форвардинг включён (текущая сессия)"
  fi
  
  if grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf; then
    log_info "✓ Настройка уже сохранена в /etc/sysctl.conf"
  else
    log_info "Сохранение настройки в /etc/sysctl.conf..."
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    log_info "✓ Настройка сохранена (сохранится после перезагрузки)"
  fi
  
  sysctl -p > /dev/null 2>&1
  
  FINAL_VALUE=$(sysctl -n net.ipv4.ip_forward)
  if [ "$FINAL_VALUE" = "1" ]; then
    log_info "✓ IP-форвардинг успешно настроен"
  else
    log_error "Не удалось включить IP-форвардинг"
  fi
}

# ==============================================================================
# ФУНКЦИЯ: НАСТРОЙКА FIREWALL (UFW)
# ==============================================================================
setup_firewall() {
  log_info "Настройка firewall (UFW)..."
  
  if command -v ufw &> /dev/null; then
    ufw --force enable
    ufw default deny incoming
    ufw default allow outgoing
    
    ufw allow 22/tcp comment 'SSH access'
    ufw allow 80/tcp comment 'HTTP for certbot'
    ufw allow 443/tcp comment 'HTTPS/VLESS traffic'
    ufw allow ${PANEL_PORT}/tcp comment '3X-UI panel'
    
    ufw reload
    
    log_info "✓ Firewall настроен"
    log_warn "Открытые порты:"
    echo "  - 22/tcp (SSH)"
    echo "  - 80/tcp (HTTP)"
    echo "  - 443/tcp (HTTPS/VLESS)"
    echo "  - ${PANEL_PORT}/tcp (Panel)"
  else
    log_warn "UFW не найден. Пропускаем настройку firewall"
  fi
}

# ==============================================================================
# ФУНКЦИЯ: НАСТРОЙКА SSH-КЛЮЧЕЙ
# ==============================================================================
setup_ssh_keys() {
  log_info "Настройка SSH-аутентификации по ключам..."
  
  if [ ! -d /root/.ssh ]; then
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
  fi
  
  if [ ! -f /root/.ssh/authorized_keys ]; then
    touch /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
  fi
  
  # КРИТИЧЕСКАЯ ПРОВЕРКА: есть ли уже ключи?
  if [ ! -s /root/.ssh/authorized_keys ]; then
    log_warn "⚠️  ВНИМАНИЕ: Файл authorized_keys пуст!"
    log_warn "Если вы отключите вход по паролю сейчас, вы потеряете доступ к серверу."
    read -p "Вы уже добавили свой публичный ключ? (y/n): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
      log_warn "Пропуск отключения парольной аутентификации для предотвращения блокировки."
      log_warn "Добавьте ключ командой: nano /root/.ssh/authorized_keys"
      log_warn "После добавления ключа выполните:"
      log_warn "  sed -i 's/^PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config"
      log_warn "  systemctl restart ssh"
      return 0
    fi
  fi
  
  SSHD_CONFIG="/etc/ssh/sshd_config"
  
  cp "$SSHD_CONFIG" "${SSHD_CONFIG}.backup.$(date +%s)"
  
  if grep -q "^PasswordAuthentication yes" "$SSHD_CONFIG"; then
    sed -i 's/^PasswordAuthentication yes/PasswordAuthentication no/' "$SSHD_CONFIG"
  elif grep -q "^#PasswordAuthentication" "$SSHD_CONFIG"; then
    sed -i 's/^#PasswordAuthentication.*/PasswordAuthentication no/' "$SSHD_CONFIG"
  else
    echo "PasswordAuthentication no" >> "$SSHD_CONFIG"
  fi
  
  systemctl restart ssh
  log_info "✓ Парольная аутентификация SSH отключена"
  log_info "✓ SSH настроен и перезапущен"
}

# ==============================================================================
# ФУНКЦИЯ: УСТАНОВКА И НАСТРОЙКА FAIL2BAN
# ==============================================================================
install_fail2ban() {
  log_info "Установка Fail2Ban..."
  
  apt-get update -qq
  apt-get install -y fail2ban
  
  cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
bantime = 86400
findtime = 600
maxretry = 3
backend = auto
banaction = iptables-multiport

[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 86400
EOF
  
  systemctl enable fail2ban
  systemctl restart fail2ban
  
  log_info "✓ Fail2Ban установлен и настроен"
}

# ==============================================================================
# ФУНКЦИЯ: ЗАПУСК СЕРВИСОВ
# ==============================================================================
start_services() {
  log_info "Запуск сервисов Docker..."
  
  docker compose down 2>/dev/null || true
  docker compose up -d
  
  log_info "Ожидание запуска сервисов..."
  sleep 15
  
  if docker compose ps | grep -q "Up"; then
    log_info "✓ Сервисы запущены успешно!"
    docker compose ps
  else
    log_error "Не удалось запустить сервисы"
  fi
}

# ==============================================================================
# ФУНКЦИЯ: ВЫВОД ИНФОРМАЦИИ ПОСЛЕ УСТАНОВКИ
# ==============================================================================
show_info() {
  echo ""
  log_info "============================================================"
  log_info "✓ УСТАНОВКА ЗАВЕРШЕНА УСПЕШНО!"
  log_info "============================================================"
  echo ""
  
  SERVER_IP=$(curl -s ifconfig.me || echo "ВАШ_IP")
  
  log_info "📊 ПАНЕЛЬ 3X-UI:"
  echo "  URL: http://${SERVER_IP}:${PANEL_PORT}${PANEL_PATH}"
  echo "  Логин: ${PANEL_USERNAME}"
  echo "  Пароль: ${PANEL_PASSWORD}"
  echo ""
  
  log_warn "⚠️  ВАЖНО: Смените пароль после первого входа!"
  echo ""
  
  log_info "🐳 PORTAINER (СКРЫТЫЙ ДОСТУП):"
  echo "  URL: http://localhost:${PORTAINER_PORT}"
  echo "  Логин: ${PORTAINER_USERNAME}"
  echo "  Пароль: ${PORTAINER_PASSWORD}"
  echo "  Доступ только через SSH-туннель:"
  echo "  ssh -L ${PORTAINER_PORT}:localhost:${PORTAINER_PORT} root@${SERVER_IP}"
  echo ""
  
  log_info "🔐 VLESS + REALITY ПАРАМЕТРЫ:"
  echo "  Порт: ${VLESS_PORT}"
  echo "  UUID: $UUID"
  echo "  Public Key: $REALITY_PUBLIC_KEY"
  echo "  Short ID: $REALITY_SHORT_ID"
  echo "  SNI: ${REALITY_SNI}"
  echo ""
  
  log_info "📋 ПОЛЕЗНЫЕ КОМАНДЫ:"
  echo "  docker compose ps              # Статус контейнеров"
  echo "  docker compose logs -f         # Просмотр логов"
  echo "  docker compose restart         # Перезапуск"
  echo "  docker compose down            # Остановка"
  echo ""
  
  log_info "============================================================"
  echo ""
}

# ==============================================================================
# ОСНОВНАЯ ФУНКЦИЯ
# ==============================================================================
main() {
  log_info "============================================================"
  log_info "🚀 НАЧАЛО УСТАНОВКИ VLESS + REALITY"
  log_info "============================================================"
  echo ""
  
  check_requirements
  generate_config
  setup_ip_forwarding
  setup_firewall
  setup_ssh_keys
  install_fail2ban
  start_services
  show_info
  
  log_info "✅ Установка завершена!"
}

# ==============================================================================
# ТОЧКА ВХОДА В СКРИПТ
# ==============================================================================
main "$@"
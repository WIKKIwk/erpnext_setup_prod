#!/usr/bin/env bash
set -euo pipefail

# === Configurable defaults ===
ERP_USER="${ERP_USER:-frappe}"
ERP_USER_PASSWORD="${ERP_USER_PASSWORD:-1}"
DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:-1}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-1}"
SITE_NAME="${SITE_NAME:-erp.local}"
BENCH_DIR="${BENCH_DIR:-/opt/erpnext}"
BENCH_NAME="${BENCH_NAME:-erpnext-bench}"
FRAPPE_BRANCH="${FRAPPE_BRANCH:-version-15}"
WKHTML_DEB_URL="${WKHTML_DEB_URL:-https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6-1/wkhtmltox_0.12.6-1.focal_amd64.deb}"
NODE_SETUP_URL="${NODE_SETUP_URL:-https://deb.nodesource.com/setup_18.x}"
BENCH_VERSION="${BENCH_VERSION:-5.27.0}"

prompt_for_secret() {
  local var_name="$1"
  local prompt_text="$2"
  local value
  if [[ -n "${!var_name-}" ]]; then
    return
  fi
  while true; do
    read -rsp "${prompt_text}: " value
    echo
    if [[ -n "${value}" ]]; then
      printf -v "${var_name}" '%s' "${value}"
      break
    fi
    echo "Value cannot be empty."
  done
}

log() {
  printf '\n[%s] %s\n' "$(date -u +'%Y-%m-%d %H:%M:%S')" "$*"
}

die() {
  log "ERROR: $*" >&2
  exit 1
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Run this script as root (use sudo)."
  fi
}

check_ubuntu() {
  if [[ ! -f /etc/os-release ]]; then
    die "/etc/os-release not found; unsupported system."
  fi
  . /etc/os-release
  if [[ "${ID}" != "ubuntu" ]]; then
    die "This script targets Ubuntu only (detected ${ID})."
  fi
  if [[ ${VERSION_ID} != 24.* ]]; then
    die "Ubuntu ${VERSION_ID} detected. Please use Ubuntu 24.x."
  fi
}

run_step() {
  local description="$1"
  shift
  log "${description}"
  "$@"
}

configure_apt() {
  export DEBIAN_FRONTEND=noninteractive
  run_step "Updating apt cache" apt-get update
  run_step "Installing base packages" apt-get install -y \
    build-essential \
    ca-certificates \
    curl \
    debianutils \
    git \
    htop \
    libffi-dev \
    libssl-dev \
    libjpeg8-dev \
    liblcms2-dev \
    libmysqlclient-dev \
    libtiff5-dev \
    libwebp-dev \
    libxrender1 \
    libxext6 \
    locales \
    mariadb-client \
    mariadb-server \
    nginx \
    nodejs \
    npm \
    python3 \
    python3-dev \
    python3-pip \
    python3-venv \
    python3-wheel \
    redis-server \
    supervisor \
    unzip \
    xfonts-75dpi \
    xfonts-base
}

install_node() {
  if ! command -v node >/dev/null || ! node -v | grep -q '^v18'; then
    run_step "Installing Node.js 18 LTS" bash -c "curl -fsSL ${NODE_SETUP_URL} | bash -"
    run_step "Installing nodejs package" apt-get install -y nodejs
  fi
  run_step "Installing Yarn globally" npm install -g yarn >/dev/null 2>&1 || npm install -g yarn
}

install_pipx() {
  run_step "Installing pipx" apt-get install -y pipx
}

install_wkhtml() {
  if command -v wkhtmltopdf >/dev/null && wkhtmltopdf --version 2>/dev/null | grep -q '0.12.6'; then
    log "wkhtmltopdf 0.12.6 already present"
    return
  fi
  run_step "Removing distro wkhtmltopdf if present" apt-get remove -y wkhtmltopdf || true
  local deb_path="/tmp/wkhtmltox.deb"
  run_step "Downloading wkhtmltopdf 0.12.6" curl -L -o "${deb_path}" "${WKHTML_DEB_URL}"
  run_step "Installing wkhtmltopdf 0.12.6" bash -c "dpkg -i ${deb_path} || apt-get install -f -y"
}

secure_mariadb() {
  systemctl enable --now mariadb >/dev/null 2>&1 || true
  cat <<'CNF' >/etc/mysql/mariadb.conf.d/99-erpnext.cnf
[mysqld]
innodb-file-per-table = 1
max_allowed_packet = 64M
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci
skip-external-locking = 1
sql_mode = ""
CNF
  systemctl restart mariadb
  log "Securing MariaDB users and defaults"
  MYSQL_CMD=(mysql --user=root)
  if ! "${MYSQL_CMD[@]}" -e "SELECT 1;" >/dev/null 2>&1; then
    MYSQL_CMD=(mysql --user=root --password="${DB_ROOT_PASSWORD}")
  fi
  "${MYSQL_CMD[@]}" <<SQL
ALTER USER 'root'@'localhost' IDENTIFIED VIA mysql_native_password;
SET PASSWORD FOR 'root'@'localhost' = PASSWORD('${DB_ROOT_PASSWORD}');
DELETE FROM mysql.user WHERE User='';
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
SQL
}

configure_redis() {
  systemctl enable --now redis-server
}

create_erp_user() {
  if id -u "${ERP_USER}" >/dev/null 2>&1; then
    log "User ${ERP_USER} already exists"
  else
    run_step "Creating user ${ERP_USER}" adduser --disabled-password --gecos "" "${ERP_USER}"
    echo "${ERP_USER}:${ERP_USER_PASSWORD}" | chpasswd
    usermod -aG sudo "${ERP_USER}"
  fi
  mkdir -p "${BENCH_DIR}"
  chown -R "${ERP_USER}:${ERP_USER}" "${BENCH_DIR}"
  sudo -u "${ERP_USER}" -H bash -c "grep -qxF 'export PATH=\$HOME/.local/bin:\$PATH' ~/.bashrc || echo 'export PATH=\$HOME/.local/bin:\$PATH' >> ~/.bashrc"
}

install_bench() {
  run_step "Installing bench via pipx" sudo -u "${ERP_USER}" -H bash -c "pipx install --force frappe-bench==${BENCH_VERSION}"
  # ensure ~/.local/bin is on PATH for non-login contexts
  sudo -u "${ERP_USER}" -H bash -c "pipx ensurepath >/dev/null 2>&1 || true"
}

link_bench_binary() {
  local bench_binary="/home/${ERP_USER}/.local/bin/bench"
  if [[ ! -x "${bench_binary}" ]]; then
    die "bench binary not found at ${bench_binary}"
  fi
  ln -sf "${bench_binary}" /usr/local/bin/bench
}

ensure_process_manager() {
  run_step "Installing process manager (honcho)" sudo -u "${ERP_USER}" -H bash -c "pipx install --force honcho"
}

setup_bench_instance() {
  sudo -u "${ERP_USER}" -H bash -c 'set -euo pipefail
export PATH=$HOME/.local/bin:$PATH
cd "'"${BENCH_DIR}"'"
if [[ ! -d "'"${BENCH_NAME}"'" ]]; then
  bench init "'"${BENCH_NAME}"'" --frappe-branch "'"${FRAPPE_BRANCH}"'" --python python3
fi
cd "'"${BENCH_NAME}"'"
if [[ ! -d apps/erpnext ]]; then
  bench get-app --branch "'"${FRAPPE_BRANCH}"'" erpnext
fi
if [[ ! -d sites/"'"${SITE_NAME}"'" ]]; then
  bench new-site "'"${SITE_NAME}"'" --db-root-password "'"${DB_ROOT_PASSWORD}"'" --admin-password "'"${ADMIN_PASSWORD}"'" --install-app frappe
fi
bench --site "'"${SITE_NAME}"'" install-app erpnext
bench --site "'"${SITE_NAME}"'" execute frappe.db.set_single_value --kwargs "{\"doctype\":\"Website Settings\",\"fieldname\":\"disable_signup\",\"value\":0}"
bench use "'"${SITE_NAME}"'"
'
}

setup_production_services() {
  run_step "Configuring supervisor/nginx for production" bash -c "
    cd '${BENCH_DIR}/${BENCH_NAME}' && \
    HOME='/home/${ERP_USER}' bench setup production --yes '${ERP_USER}'
  "
  run_step "Restarting production services" bash -c "
    cd '${BENCH_DIR}/${BENCH_NAME}' && HOME='/home/${ERP_USER}' bench restart
  "
}

finalize_hosts() {
  if ! grep -q "${SITE_NAME}" /etc/hosts; then
    echo "127.0.0.1 ${SITE_NAME}" >> /etc/hosts
  fi
}

main() {
  require_root
  check_ubuntu
  prompt_for_secret ERP_USER_PASSWORD "Enter password for Linux user ${ERP_USER}"
  prompt_for_secret DB_ROOT_PASSWORD "Enter MariaDB root password"
  prompt_for_secret ADMIN_PASSWORD "Enter ERPNext Administrator password"
  configure_apt
  install_node
  install_pipx
  install_wkhtml
  secure_mariadb
  configure_redis
  create_erp_user
  install_bench
  link_bench_binary
  ensure_process_manager
  setup_bench_instance
  setup_production_services
  finalize_hosts
  log "All done. ERPNext services run via supervisor/nginx. Use 'sudo systemctl restart supervisor' or 'bench restart' inside ${BENCH_DIR}/${BENCH_NAME} when needed."
}

main "$@"


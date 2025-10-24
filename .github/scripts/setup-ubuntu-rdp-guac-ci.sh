#!/usr/bin/env bash
# setup-ubuntu-rdp-guac-ci.sh
# CI-friendly install for XRDP + Guacamole with a preconfigured connection

set -euo pipefail
IFS=$'\n\t'

###############################################
# Config (CI-safe defaults)
###############################################
TARGET_USER="${TARGET_USER:-ciuser}"
RDP_PORT="${RDP_PORT:-3389}"
GUAC_PORT="${GUAC_PORT:-8080}"
INSTALL_DIR="${INSTALL_DIR:-/opt/ubuntu-rdp-setup}"
UBUNTU_DESKTOP="${UBUNTU_DESKTOP:-xfce4}"

GITHUB_TOKEN="${GITHUB_TOKEN:-}"
GITHUB_REPO="${GITHUB_REPO:-}"
CREATE_GITHUB="${CREATE_GITHUB:-false}"
GIT_NAME="${GIT_NAME:-GitHub Action Bot}"
GIT_EMAIL="${GIT_EMAIL:-actions@github.com}"

###############################################
# Helpers
###############################################
log()  { echo -e "\033[1;34m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err()  { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; exit 1; }

###############################################
# System prep
###############################################
log "Updating apt packages..."
apt-get update -y -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  xrdp dbus-x11 ${UBUNTU_DESKTOP} ${UBUNTU_DESKTOP}-goodies \
  xorgxrdp git curl jq docker.io docker-compose-plugin openssh-server

systemctl enable ssh || true
systemctl start ssh || true
systemctl enable xrdp || true
systemctl start xrdp || true

###############################################
# Create default user
###############################################
if ! id "$TARGET_USER" &>/dev/null; then
  log "Creating user: $TARGET_USER"
  useradd -m -s /bin/bash "$TARGET_USER"
  echo "$TARGET_USER:password" | chpasswd
  usermod -aG sudo "$TARGET_USER" || true
fi

###############################################
# Firewall
###############################################
if command -v ufw >/dev/null 2>&1; then
  ufw allow 22/tcp || true
  ufw allow ${RDP_PORT}/tcp || true
  ufw allow ${GUAC_PORT}/tcp || true
  ufw --force enable || true
fi

###############################################
# Build custom Guacamole image (with SSH connection)
###############################################
GUAC_BUILD_DIR="/opt/guacamole-build"
mkdir -p "$GUAC_BUILD_DIR"
cd "$GUAC_BUILD_DIR"

# Default SQL init for PostgreSQL with a preconfigured SSH connection
cat > initdb.sql <<'EOF'
-- Create default user
INSERT INTO guacamole_user (username, password_hash, password_salt, disabled, expired, access_window_start, access_window_end, valid_from, valid_until, timezone)
VALUES ('guacadmin', ENCODE(DIGEST('guacadmin' || 'salt123', 'SHA256'), 'hex'), 'salt123', 0, 0, NULL, NULL, NULL, NULL, 'UTC');

-- Create default SSH connection
INSERT INTO guacamole_connection (connection_name, protocol, max_connections, max_connections_per_user)
VALUES ('Local SSH', 'ssh', 5, 5);
INSERT INTO guacamole_connection_parameter (connection_id, parameter_name, parameter_value)
VALUES ((SELECT connection_id FROM guacamole_connection WHERE connection_name='Local SSH'), 'hostname', 'localhost'),
       ((SELECT connection_id FROM guacamole_connection WHERE connection_name='Local SSH'), 'port', '22'),
       ((SELECT connection_id FROM guacamole_connection WHERE connection_name='Local SSH'), 'username', 'ciuser');
EOF

# Dockerfile for preloaded image
cat > Dockerfile <<'EOF'
FROM guacamole/guacamole:latest
COPY initdb.sql /initdb/initdb.sql
EOF

docker build -t guac-custom:latest .

###############################################
# Docker Compose stack
###############################################
GUAC_DIR="/opt/guacamole"
mkdir -p "$GUAC_DIR"
cat > "$GUAC_DIR/docker-compose.yml" <<EOF
version: "3.8"
services:
  guacd:
    image: guacamole/guacd:latest
    container_name: guacd
    restart: always

  postgres:
    image: postgres:15
    container_name: guac-db
    restart: always
    environment:
      POSTGRES_DB: guacamole_db
      POSTGRES_USER: guac_db_user
      POSTGRES_PASSWORD: some_password
    volumes:
      - db_data:/var/lib/postgresql/data
      - ${GUAC_BUILD_DIR}/initdb.sql:/docker-entrypoint-initdb.d/initdb.sql:ro

  guacamole:
    image: guac-custom:latest
    container_name: guacamole
    restart: always
    depends_on:
      - guacd
      - postgres
    environment:
      GUACD_HOSTNAME: guacd
      POSTGRES_HOSTNAME: postgres
      POSTGRES_DATABASE: guacamole_db
      POSTGRES_USER: guac_db_user
      POSTGRES_PASSWORD: some_password
    ports:
      - "${GUAC_PORT}:8080"

volumes:
  db_data:
EOF

cd "$GUAC_DIR"
docker compose up -d

sleep 10
if docker ps | grep -q guacamole; then
  log "✅ Guacamole running at: http://$(hostname -I | awk '{print $1}'):${GUAC_PORT}/guacamole"
  log "   Login: guacadmin / guacadmin"
  log "   Connection: 'Local SSH' -> localhost:22 (user: ciuser / password)"
else
  warn "Guacamole containers failed to start — check logs."
fi

###############################################
# Save artifacts
###############################################
mkdir -p "$INSTALL_DIR"
cp -f "$0" "$INSTALL_DIR/setup-ubuntu-rdp-guac-ci.sh"
cat > "$INSTALL_DIR/README.md" <<EOF
# Ubuntu RDP + Guacamole (CI-ready)
- XRDP + XFCE (port ${RDP_PORT})
- Guacamole (port ${GUAC_PORT})
- Preconfigured SSH connection to localhost
- Default login: guacadmin / guacadmin
EOF

###############################################
# Optional GitHub push
###############################################
cd "$INSTALL_DIR"
git init -q
git config user.name "$GIT_NAME"
git config user.email "$GIT_EMAIL"
git add -A
git commit -m "CI build: Ubuntu RDP + Guacamole with default SSH connection" || true

if [[ "$CREATE_GITHUB" == "true" && -n "$GITHUB_REPO" && -n "$GITHUB_TOKEN" ]]; then
  log "Pushing setup artifacts to GitHub repo: $GITHUB_REPO"
  git remote add origin "https://${GITHUB_TOKEN}@github.com/${GITHUB_REPO}.git"
  git branch -M main
  git push -u origin main --force || warn "Push failed (token permissions?)."
  git remote set-url origin "https://github.com/${GITHUB_REPO}.git"
fi

###############################################
# Done
###############################################
log "✅ CI setup finished — Guacamole is preloaded and ready."

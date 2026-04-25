#!/bin/bash
# ═══════════════════════════════════════════════════════
#  VPS Setup: базовая безопасность + AmneziaWG (Docker)
#  Ubuntu 20.04 / 22.04 / 24.04
# ═══════════════════════════════════════════════════════
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
log()     { echo -e "${GREEN}[+]${NC} $*"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*"; }
die()     { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }
section() { echo -e "\n${BLUE}${BOLD}── $* ──${NC}"; }

[[ $EUID -ne 0 ]] && die "Запусти от root: sudo $0"

# ════════════════════════════════════════════════════════
#  НАСТРОЙКИ
# ════════════════════════════════════════════════════════
USERNAME="magway"
SSH_PORT=222
AWG_PORT=5454
AWG_CLIENT_NAME="magway"
AWG_IMAGE="metaligh/amneziawg"
AWG_DIR="/opt/amneziawg"
AWG_SERVER_ADDR="10.8.0.1/24"
AWG_CLIENT_ADDR="10.8.0.2/32"
DNS="1.1.1.1,1.0.0.1"
# ════════════════════════════════════════════════════════

SERVER_IP=$(curl -sf https://ifconfig.me 2>/dev/null \
         || curl -sf https://icanhazip.com 2>/dev/null \
         || die "Не удалось определить публичный IP")
log "Публичный IP: $SERVER_IP"

# ──────────────────────────────────────────────────────
section "1 / Обновление системы"
# ──────────────────────────────────────────────────────
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    curl wget ufw fail2ban iptables \
    apt-transport-https ca-certificates gnupg lsb-release \
    wireguard-tools unattended-upgrades

cat > /etc/apt/apt.conf.d/20auto-upgrades << 'APTEOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APTEOF
log "Автоматические security-обновления включены"

# ──────────────────────────────────────────────────────
section "2 / Пользователь $USERNAME"
# ──────────────────────────────────────────────────────
if ! id "$USERNAME" &>/dev/null; then
    useradd -m -s /bin/bash "$USERNAME"
    log "Пользователь создан"
else
    log "Пользователь уже существует"
fi

usermod -aG sudo "$USERNAME"
echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/"$USERNAME"
chmod 440 /etc/sudoers.d/"$USERNAME"
log "sudo без пароля — ОК"

SSH_PUBKEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPTiZ3fqSiFg8mDV1iLEWEioqnbs2R/KgRuQvTQPug1z magway@MacBook-Pro-Magway.local"

SSH_DIR="/home/$USERNAME/.ssh"
AUTHKEYS="$SSH_DIR/authorized_keys"
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"
echo "$SSH_PUBKEY" > "$AUTHKEYS"
chmod 600 "$AUTHKEYS"
chown -R "$USERNAME:$USERNAME" "$SSH_DIR"
log "SSH-ключ добавлен"

# ──────────────────────────────────────────────────────
section "3 / SSH hardening (порт $SSH_PORT)"
# ──────────────────────────────────────────────────────
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
mkdir -p /etc/ssh/sshd_config.d

cat > /etc/ssh/sshd_config.d/99-hardening.conf << EOF
Port $SSH_PORT
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
PermitEmptyPasswords no
ChallengeResponseAuthentication no
X11Forwarding no
MaxAuthTries 3
LoginGraceTime 20
ClientAliveInterval 300
ClientAliveCountMax 2
AllowUsers $USERNAME
EOF

systemctl restart ssh 2>/dev/null || systemctl restart sshd
log "SSHD перезапущен на порту $SSH_PORT"

# ──────────────────────────────────────────────────────
section "4 / UFW"
# ──────────────────────────────────────────────────────
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow "$SSH_PORT/tcp"  comment "SSH"
ufw allow "$AWG_PORT/udp"  comment "AmneziaWG"
ufw --force enable
log "UFW включён: SSH $SSH_PORT/tcp, AWG $AWG_PORT/udp"

# ──────────────────────────────────────────────────────
section "5 / fail2ban"
# ──────────────────────────────────────────────────────
cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
ignoreip = 127.0.0.1/8 ::1

[sshd]
enabled = true
port    = $SSH_PORT
logpath = %(sshd_log)s
backend = systemd
EOF

systemctl enable --quiet fail2ban
systemctl restart fail2ban
log "fail2ban настроен"

# ──────────────────────────────────────────────────────
section "6 / Docker"
# ──────────────────────────────────────────────────────
if ! command -v docker &>/dev/null; then
    log "Устанавливаю Docker..."
    curl -fsSL https://get.docker.com | sh
    usermod -aG docker "$USERNAME"
    systemctl enable --quiet docker
    systemctl start docker
    log "Docker установлен: $(docker --version)"
else
    log "Docker уже есть: $(docker --version | cut -d' ' -f3 | tr -d ',')"
fi

# ──────────────────────────────────────────────────────
section "7 / AmneziaWG"
# ──────────────────────────────────────────────────────
mkdir -p "$AWG_DIR/config"

# Ключи
SERVER_PRIVKEY=$(wg genkey)
SERVER_PUBKEY=$(echo "$SERVER_PRIVKEY" | wg pubkey)
CLIENT_PRIVKEY=$(wg genkey)
CLIENT_PUBKEY=$(echo "$CLIENT_PRIVKEY" | wg pubkey)
PSK=$(wg genpsk)

# AWG obfuscation — случайные параметры для каждого сервера
AWG_JC=$(shuf -i 3-10 -n 1)
AWG_JMIN=$(shuf -i 40-70 -n 1)
AWG_JMAX=$(( AWG_JMIN + $(shuf -i 10-40 -n 1) ))
AWG_S1=$(shuf -i 10-150 -n 1)
AWG_S2=$(shuf -i 10-150 -n 1)
read -r AWG_H1 AWG_H2 AWG_H3 AWG_H4 < <(
    python3 -c "import random; v=random.sample(range(1,2**32),4); print(*v)"
)

# Основной сетевой интерфейс хоста (для NAT)
NET_IFACE=$(ip route show default | awk '/default/ {print $5; exit}')
[[ -z "$NET_IFACE" ]] && die "Не определён сетевой интерфейс"
log "Сетевой интерфейс для NAT: $NET_IFACE"

# Серверный конфиг
cat > "$AWG_DIR/config/wg0.conf" << EOF
[Interface]
PrivateKey = $SERVER_PRIVKEY
Address    = $AWG_SERVER_ADDR
ListenPort = $AWG_PORT

PostUp   = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -o $NET_IFACE -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT; iptables -t nat -D POSTROUTING -o $NET_IFACE -j MASQUERADE

Jc   = $AWG_JC
Jmin = $AWG_JMIN
Jmax = $AWG_JMAX
S1   = $AWG_S1
S2   = $AWG_S2
H1   = $AWG_H1
H2   = $AWG_H2
H3   = $AWG_H3
H4   = $AWG_H4

[Peer]
# $AWG_CLIENT_NAME
PublicKey    = $CLIENT_PUBKEY
PresharedKey = $PSK
AllowedIPs   = $AWG_CLIENT_ADDR
EOF
chmod 600 "$AWG_DIR/config/wg0.conf"

# Клиентский конфиг
CLIENT_CONF="$AWG_DIR/${AWG_CLIENT_NAME}.conf"
cat > "$CLIENT_CONF" << EOF
[Interface]
PrivateKey = $CLIENT_PRIVKEY
Address    = $AWG_CLIENT_ADDR
DNS        = $DNS

Jc   = $AWG_JC
Jmin = $AWG_JMIN
Jmax = $AWG_JMAX
S1   = $AWG_S1
S2   = $AWG_S2
H1   = $AWG_H1
H2   = $AWG_H2
H3   = $AWG_H3
H4   = $AWG_H4

[Peer]
PublicKey           = $SERVER_PUBKEY
PresharedKey        = $PSK
Endpoint            = $SERVER_IP:$AWG_PORT
AllowedIPs          = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF
chmod 600 "$CLIENT_CONF"

# docker-compose.yml
cat > "$AWG_DIR/docker-compose.yml" << EOF
services:
  amneziawg:
    image: $AWG_IMAGE
    container_name: amneziawg
    restart: unless-stopped
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    volumes:
      - ./config:/etc/wireguard
    ports:
      - "${AWG_PORT}:${AWG_PORT}/udp"
    sysctls:
      - net.ipv4.conf.all.src_valid_mark=1
      - net.ipv4.ip_forward=1
    devices:
      - /dev/net/tun:/dev/net/tun
EOF

# IP forwarding на хосте
sysctl -w net.ipv4.ip_forward=1 > /dev/null
if grep -q '^#*net.ipv4.ip_forward' /etc/sysctl.conf; then
    sed -i 's/^#*net.ipv4.ip_forward.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf
else
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
fi

cd "$AWG_DIR"
docker compose pull -q
docker compose up -d
log "AmneziaWG запущен"

# ──────────────────────────────────────────────────────
section "Готово"
# ──────────────────────────────────────────────────────
echo ""
echo -e "  ${BOLD}SSH:${NC}           ssh -p $SSH_PORT $USERNAME@$SERVER_IP"
echo -e "  ${BOLD}AWG конфиг:${NC}    $CLIENT_CONF"
echo -e "  ${BOLD}AWG директория:${NC} $AWG_DIR"
echo ""
echo -e "${YELLOW}▼ $AWG_CLIENT_NAME.conf ▼${NC}"
cat "$CLIENT_CONF"
echo ""
warn "Не закрывай эту сессию, пока не проверишь SSH на порту $SSH_PORT!"
warn "Тест: ssh -p $SSH_PORT $USERNAME@$SERVER_IP"

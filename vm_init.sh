#!/bin/bash

set -euo pipefail

# ==============================================================================
# 🚀 SCRIPT DE INICIALIZAÇÃO DA VM
# ==============================================================================

# ------------------------------------------------------------------------------
# 🛠️ CONFIGURAÇÕES — CARREGADAS DO .ENV NA RAIZ
# ------------------------------------------------------------------------------

load_env() {
    local ENV_FILE=""
    if [ -f "$(dirname "$0")/.env" ]; then
        ENV_FILE="$(dirname "$0")/.env"
    elif [ -f ".env" ]; then
        ENV_FILE=".env"
    fi

    if [ -n "$ENV_FILE" ]; then
        # FIX: loop seguro no lugar de export $(xargs) — suporta valores com espaços e caracteres especiais
        while IFS='=' read -r KEY VALUE; do
            [[ "$KEY" =~ ^#.*$ || -z "$KEY" ]] && continue
            export "$KEY=$VALUE"
        done < <(grep -v '^#' "$ENV_FILE")
    fi
}

load_env

CLIENTE_SENHA_VPN="${CLIENTE_SENHA_VPN:-}"
DOCKER_VOLUME_BD="${DOCKER_VOLUME_BD:-dados_postgres}"
DOCKER_NETWORK="${DOCKER_NETWORK:-minha-rede}"

# ------------------------------------------------------------------------------
# ⚙️ CONFIGURAÇÕES GERAIS — normalmente não precisa alterar
# ------------------------------------------------------------------------------

PASTA_SCRIPTS="${PASTA_SCRIPTS:-/home/ubuntu/scripts}"
LOG_FILE="${VM_INIT_LOG:-/var/log/vm_init.log}"
BACKUP_LOG="${BACKUP_LOG:-/var/log/backup_banco.log}"
NOME_CLIENTE_VPN="${NOME_CLIENTE_VPN:-dev-cliente}"

# ==============================================================================
# VALIDAÇÕES INICIAIS
# ==============================================================================

if [ "$(id -u)" -ne 0 ]; then
    echo "❌ Este script precisa ser rodado como root."
    exit 1
fi

# FIX: validação de senha robusta — mínimo 12 caracteres, não vazia, sem placeholders
ERRO_VARS=0
for VAR in CLIENTE_SENHA_VPN; do
    VALOR="${!VAR}"
    if [ -z "$VALOR" ]; then
        echo "❌ ERRO: $VAR está vazia."
        ERRO_VARS=1
    elif [[ "$VALOR" == *"Senha"* && "$VALOR" == *"Aqui"* ]]; then
        echo "❌ ERRO: $VAR ainda contém o valor placeholder."
        ERRO_VARS=1
    elif [ "${#VALOR}" -lt 12 ]; then
        echo "❌ ERRO: $VAR deve ter pelo menos 12 caracteres (tem ${#VALOR})."
        ERRO_VARS=1
    fi
done
[ "$ERRO_VARS" -eq 1 ] && exit 1

# ==============================================================================
# FUNÇÕES AUXILIARES
# ==============================================================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

step() {
    echo ""
    echo "======================================================================="
    echo " $*"
    echo "======================================================================="
    log "STEP: $*"
}

# ==============================================================================
log "🚀 Início do script de inicialização da VM"
# ==============================================================================

step "[1/9] Atualizando o Sistema Operacional"
# ==============================================================================

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
apt-get install -y curl git ufw fail2ban iptables wireguard iptables-persistent

# ==============================================================================
step "[2/9] Instalando o Docker e o Docker Compose"
# ==============================================================================

if command -v docker &>/dev/null; then
    log "Docker já instalado — pulando."
else
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    sh /tmp/get-docker.sh
    rm -f /tmp/get-docker.sh
fi

systemctl enable docker
systemctl start docker
usermod -aG docker ubuntu

log "✅ Docker $(docker --version) instalado e ativo."

# ==============================================================================
step "[3/9] Configurando a VPN (WireGuard)"
# ==============================================================================

export INTERACTIVE=0
export APPROVE_INSTALL=y
export APPROVE_IP=y
export IPV6_SUPPORT=n
export PORT=51820
export PROTOCOL=1
export CLIENT_NAME="$NOME_CLIENTE_VPN"
export DNS=1

curl -fsSL https://raw.githubusercontent.com/angristan/wireguard-install/master/wireguard-install.sh \
    -o /tmp/wireguard-install.sh
chmod +x /tmp/wireguard-install.sh
/tmp/wireguard-install.sh
rm -f /tmp/wireguard-install.sh

log "✅ WireGuard configurado. Arquivo do cliente: /root/wg0-client-${NOME_CLIENTE_VPN}.conf"

# ==============================================================================
step "[4/9] Configurando o Firewall (UFW)"
# ==============================================================================

ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 80/tcp   comment 'HTTP Nginx'
ufw allow 443/tcp  comment 'HTTPS Nginx'
ufw allow 51820/udp comment 'VPN WireGuard'
ufw allow 22/tcp   comment 'SSH externo (chave publica)'
ufw --force enable

log "✅ UFW ativo."

# ==============================================================================
step "[5/9] Configurando Fail2Ban"
# ==============================================================================

cat << 'EOF' > /etc/fail2ban/jail.local
[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 5

[sshd]
enabled = true
port    = 22
filter  = sshd
logpath = /var/log/auth.log
EOF

systemctl enable fail2ban
systemctl restart fail2ban

log "✅ Fail2Ban configurado (ban: 1h, janela: 10min, max tentativas: 5)."

# ==============================================================================
step "[6/9] Configurando SSH (chave pública externa, senha via VPN)"
# ==============================================================================

# FIX: desativa PermitRootLogin globalmente, não só no bloco Match
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/'   /etc/ssh/sshd_config
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/'    /etc/ssh/sshd_config

echo "ubuntu:${CLIENTE_SENHA_VPN}" | chpasswd

if ! grep -q "Match Address 10.66.66.*" /etc/ssh/sshd_config; then
    cat << 'EOF' >> /etc/ssh/sshd_config

# Acesso por senha permitido apenas via rede interna WireGuard
Match Address 10.66.66.*
    PasswordAuthentication yes
    PermitRootLogin no
EOF
fi

if sshd -t; then
    systemctl restart sshd
    log "✅ SSH reconfigurado com segurança."
else
    log "❌ ERRO: Configuração do sshd inválida! SSH não foi reiniciado."
    exit 1
fi

# ==============================================================================
step "[7/9] Criando Volume Docker do Banco de Dados e Network"
# ==============================================================================

if [ -z "$DOCKER_VOLUME_BD" ]; then
    log "⏭️  DOCKER_VOLUME_BD não preenchida — criação de volume ignorada."
else
    if docker volume inspect "$DOCKER_VOLUME_BD" &>/dev/null; then
        log "⏭️  Volume $DOCKER_VOLUME_BD já existe — pulando."
    else
        docker volume create "$DOCKER_VOLUME_BD"
        log "✅ Volume $DOCKER_VOLUME_BD criado."
    fi
    log "   Para inspecionar: docker volume inspect $DOCKER_VOLUME_BD"
fi

if [ -z "$DOCKER_NETWORK" ]; then
    log "⏭️  DOCKER_NETWORK não preenchida — criação de network ignorada."
else
    if docker network inspect "$DOCKER_NETWORK" &>/dev/null; then
        log "⏭️  Network $DOCKER_NETWORK já existe — pulando."
    else
        docker network create "$DOCKER_NETWORK"
        log "✅ Network $DOCKER_NETWORK criado."
    fi
    log "   Para inspecionar: docker network inspect $DOCKER_NETWORK"
fi

# ==============================================================================
step "[8/9] Instalando AWS CLI e Configurando Cron de Backup"
# ==============================================================================

mkdir -p "$PASTA_SCRIPTS"

if ! command -v aws &>/dev/null; then
    log "Instalando AWS CLI v2..."
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
    apt-get install -y unzip
    unzip -q /tmp/awscliv2.zip -d /tmp/aws-install
    /tmp/aws-install/aws/install
    rm -rf /tmp/awscliv2.zip /tmp/aws-install
    log "✅ AWS CLI instalado."
else
    log "AWS CLI já instalado — pulando."
fi

if [ ! -f "$PASTA_SCRIPTS/backup-bd.sh" ]; then
    log "⚠️  $PASTA_SCRIPTS/backup-bd.sh não encontrado."
    log "   Copie o arquivo para $PASTA_SCRIPTS/backup-bd.sh e preencha as credenciais AWS."
fi

CRON_JOB="0 3 * * * /bin/bash $PASTA_SCRIPTS/backup-bd.sh"
( crontab -l 2>/dev/null | grep -v "backup-bd.sh"; echo "$CRON_JOB" ) | crontab -

log "✅ Cron de backup configurado: todo dia às 03:00"
log "   Script: $PASTA_SCRIPTS/backup-bd.sh"
log "   Log:    $BACKUP_LOG"

# ==============================================================================
step "[9/9] Organizando scripts na pasta final"
# ==============================================================================

DIR_ATUAL="$(dirname "$(readlink -f "$0")")"
log "Copiando scripts de $DIR_ATUAL para $PASTA_SCRIPTS ..."

for ARQUIVO in backup-bd.sh deploy.sh restore-bd.sh .env .env-exemplo; do
    if [ -f "$DIR_ATUAL/$ARQUIVO" ]; then
        cp "$DIR_ATUAL/$ARQUIVO" "$PASTA_SCRIPTS/"
        chmod +x "$PASTA_SCRIPTS/$ARQUIVO" 2>/dev/null || true
        log "   ✅ $ARQUIVO copiado."
    fi
done

# ==============================================================================
log ""
log "🎉 =================================================="
log "   VM CONFIGURADA COM SUCESSO!"
log "   Log completo:  $LOG_FILE"
log "   Arquivo VPN:   /root/wg0-client-${NOME_CLIENTE_VPN}.conf"
log "   Volume BD:     ${DOCKER_VOLUME_BD:-não criado}"
log "   Scripts em:    $PASTA_SCRIPTS"
log "   Próximo passo: execute o deploy"
log "   sudo bash $PASTA_SCRIPTS/deploy.sh"
log "=================================================="

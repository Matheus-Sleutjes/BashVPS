#!/bin/bash
set -euo pipefail

# ==============================================================================
# ⚠️  ATENÇÃO — ARQUIVO SENSÍVEL
# ------------------------------------------------------------------------------
# Este script contém credenciais do cliente.
# NUNCA faça commit deste arquivo em repositórios git.
# NUNCA compartilhe este arquivo por e-mail, Slack ou qualquer canal aberto.
# Após o deploy, apague ou sobrescreva o campo User Data no painel do provedor.
#
# Guarde localmente em: /clientes/<nome-cliente>/vm_init.sh
# Adicione ao .gitignore: vm_init*.sh ou a pasta /clientes/ inteira
# ==============================================================================

# ------------------------------------------------------------------------------
# 🛠️  CREDENCIAIS DO CLIENTE — ALTERE APENAS AQUI PARA CADA NOVO DEPLOY
# ------------------------------------------------------------------------------
CLIENTE_SENHA_VPN="12345678"

# ------------------------------------------------------------------------------
# 🗄️  VOLUME DO BANCO DE DADOS
# Preencha para criar o volume Docker automaticamente.
# Deixe vazio ("") para ignorar a criação do volume.
# ------------------------------------------------------------------------------
DOCKER_VOLUME_BD="dados_postgres"

# ------------------------------------------------------------------------------
# 🗄️  NETWORK
# Preencha para criar a network Docker automaticamente.
# Deixe vazio ("") para ignorar a criação do volume.
# ------------------------------------------------------------------------------
DOCKER_NETWORK="dados_postgres"

# ------------------------------------------------------------------------------
# ⚙️  CONFIGURAÇÕES GERAIS — normalmente não precisa alterar
# ------------------------------------------------------------------------------
PASTA_SCRIPTS="/home/ubuntu/scripts"
LOG_FILE="/var/log/vm_init.log"
BACKUP_LOG="/var/log/backup_banco.log"
NOME_CLIENTE_VPN="dev-cliente"

# ==============================================================================
# VALIDAÇÕES INICIAIS
# ==============================================================================
if [ "$(id -u)" -ne 0 ]; then
    echo "❌ Este script precisa ser rodado como root."
    exit 1
fi

for VAR in CLIENTE_SENHA_VPN; do
    VALOR="${!VAR}"
    if [ -z "$VALOR" ] || [[ "$VALOR" == *"Senha"* && "$VALOR" == *"Aqui"* ]]; then
        echo "❌ ERRO: Variável $VAR não foi preenchida."
        exit 1
    fi
done

# ==============================================================================
# FUNÇÕES AUXILIARES
# ==============================================================================
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

step() {
    echo ""
    echo "======================================================================="
    echo "  $*"
    echo "======================================================================="
    log "STEP: $*"
}

# ==============================================================================
log "🚀 Início do script de inicialização da VM"

# ==============================================================================
step "[1/7] Atualizando o Sistema Operacional"
# ==============================================================================
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
apt-get install -y curl git ufw fail2ban iptables wireguard iptables-persistent

# ==============================================================================
step "[2/7] Instalando o Docker e o Docker Compose"
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
step "[3/7] Configurando a VPN (WireGuard)"
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
step "[4/7] Configurando o Firewall (UFW)"
# ==============================================================================
ufw --force reset
ufw default deny incoming
ufw default allow outgoing

ufw allow 80/tcp    comment 'HTTP Nginx'
ufw allow 443/tcp   comment 'HTTPS Nginx'
ufw allow 51820/udp comment 'VPN WireGuard'
ufw allow 22/tcp    comment 'SSH externo (chave publica)'

ufw --force enable
log "✅ UFW ativo."

# ==============================================================================
step "[5/7] Configurando Fail2Ban"
# ==============================================================================
cat << 'EOF' > /etc/fail2ban/jail.local
[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 5

[sshd]
enabled  = true
port     = 22
filter   = sshd
logpath  = /var/log/auth.log
EOF

systemctl enable fail2ban
systemctl restart fail2ban
log "✅ Fail2Ban configurado (ban: 1h, janela: 10min, max tentativas: 5)."

# ==============================================================================
step "[6/7] Configurando SSH (chave pública externa, senha via VPN)"
# ==============================================================================
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config

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
step "[7/8] Criando Volume Docker do Banco de Dados e Network"
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
step "[8/8] Instalando AWS CLI e Configurando Cron de Backup"
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

# O backup-bd.sh deve ser copiado para $PASTA_SCRIPTS antes que o cron rode
# Cole o arquivo em: $PASTA_SCRIPTS/backup-bd.sh
if [ ! -f "$PASTA_SCRIPTS/backup-bd.sh" ]; then
    log "⚠️  $PASTA_SCRIPTS/backup-bd.sh não encontrado."
    log "   Copie o arquivo para $PASTA_SCRIPTS/backup-bd.sh e preencha as credenciais AWS."
fi

# Registra o cron job — todo dia às 03:00
CRON_JOB="0 3 * * * /bin/bash $PASTA_SCRIPTS/backup-bd.sh"
( crontab -l 2>/dev/null | grep -v "backup-bd.sh"; echo "$CRON_JOB" ) | crontab -

log "✅ Cron de backup configurado: todo dia às 03:00"
log "   Script: $PASTA_SCRIPTS/backup-bd.sh"
log "   Log:    $BACKUP_LOG"
log "⚠️  Preencha as credenciais AWS em $PASTA_SCRIPTS/backup-bd.sh antes da meia-noite!"
# ==============================================================================
log ""
log "🎉 =================================================="
log "   VM CONFIGURADA COM SUCESSO!"
log "   Log completo:  $LOG_FILE"
log "   Arquivo VPN:   /root/wg0-client-${NOME_CLIENTE_VPN}.conf"
log "   Volume BD:     ${DOCKER_VOLUME_BD:-não criado}"
log "   Próximo passo: cole deploy.sh em $PASTA_SCRIPTS e execute"
log "                  sudo bash $PASTA_SCRIPTS/deploy.sh"
log "=================================================="
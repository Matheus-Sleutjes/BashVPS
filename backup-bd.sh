#!/bin/bash

set -euo pipefail

# ==============================================================================
# 🗄️ SCRIPT DE BACKUP DE BANCO DE DADOS
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

AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-}"
AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-}"
AWS_REGION="${AWS_REGION:-us-east-1}"
S3_BUCKET="${S3_BUCKET:-}"

CONTAINER_BANCO="${CONTAINER_BANCO:-bd_producao}"
DOCKER_VOLUME_BD="${DOCKER_VOLUME_BD:-dados_postgres}"
DB_USER="${DB_USER:-admin_usuario}"

RETENCAO_DIAS="${RETENCAO_DIAS:-7}"

# FIX: diretório dedicado para dumps — evita encher /tmp junto ao SO
DUMP_DIR="${DUMP_DIR:-/var/backups/postgres}"

# Webhook para notificação de erro (Slack/Discord/Telegram — deixe vazio para desativar)
# Slack/Discord: URL completa do webhook
# Telegram: formato "telegram:BOT_TOKEN:CHAT_ID"
WEBHOOK_NOTIFICACAO="${WEBHOOK_NOTIFICACAO:-}"

# ==============================================================================
# INICIALIZAÇÃO
# ==============================================================================

LOG="${BACKUP_LOG:-/var/log/backup_banco.log}"
DATA=$(date '+%Y-%m-%d_%H-%M-%S')
mkdir -p "$DUMP_DIR"
ARQUIVO_LOCAL="${DUMP_DIR}/backup_${DATA}.sql.gz"
ARQUIVO_S3="${S3_BUCKET}/backup_${DATA}.sql.gz"

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }
erro() {
    local LINHA="$1"
    local CMD="$2"
    log "❌ ERRO na linha $LINHA: $CMD"
    rm -f "$ARQUIVO_LOCAL"
    notificar_erro "Backup falhou na linha $LINHA: $CMD — $(hostname)"
    exit 1
}

trap 'erro $LINENO "$BASH_COMMAND"' ERR

# ==============================================================================
# NOTIFICAÇÃO
# ==============================================================================

notificar_erro() {
    local MENSAGEM="$1"
    [ -z "$WEBHOOK_NOTIFICACAO" ] && return 0

    if [[ "$WEBHOOK_NOTIFICACAO" == telegram:* ]]; then
        local BOT_TOKEN CHAT_ID
        BOT_TOKEN=$(echo "$WEBHOOK_NOTIFICACAO" | cut -d: -f2)
        CHAT_ID=$(echo "$WEBHOOK_NOTIFICACAO" | cut -d: -f3)
        curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
            -d "chat_id=${CHAT_ID}" \
            -d "text=🔴 *BACKUP FALHOU* — ${MENSAGEM}" \
            -d "parse_mode=Markdown" > /dev/null || true
    else
        # Slack ou Discord (ambos aceitam {"text": "..."})
        curl -s -X POST "$WEBHOOK_NOTIFICACAO" \
            -H "Content-Type: application/json" \
            -d "{\"text\": \"🔴 *BACKUP FALHOU* — ${MENSAGEM}\"}" > /dev/null || true
    fi
}

notificar_ok() {
    local MENSAGEM="$1"
    [ -z "$WEBHOOK_NOTIFICACAO" ] && return 0

    if [[ "$WEBHOOK_NOTIFICACAO" == telegram:* ]]; then
        local BOT_TOKEN CHAT_ID
        BOT_TOKEN=$(echo "$WEBHOOK_NOTIFICACAO" | cut -d: -f2)
        CHAT_ID=$(echo "$WEBHOOK_NOTIFICACAO" | cut -d: -f3)
        curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
            -d "chat_id=${CHAT_ID}" \
            -d "text=✅ *Backup OK* — ${MENSAGEM}" \
            -d "parse_mode=Markdown" > /dev/null || true
    else
        curl -s -X POST "$WEBHOOK_NOTIFICACAO" \
            -H "Content-Type: application/json" \
            -d "{\"text\": \"✅ *Backup OK* — ${MENSAGEM}\"}" > /dev/null || true
    fi
}

# ==============================================================================
# VALIDAÇÕES
# ==============================================================================

validar_variaveis() {
    local ERRO=0
    for VAR in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_REGION S3_BUCKET \
               CONTAINER_BANCO DOCKER_VOLUME_BD DB_USER; do
        local VALOR="${!VAR}"
        if [ -z "$VALOR" ] || [[ "$VALOR" == *"_AQUI"* ]] || [[ "$VALOR" == *"nome-do-seu"* ]]; then
            echo "❌ Variável $VAR não preenchida corretamente."
            ERRO=1
        fi
    done
    [ "$ERRO" -eq 1 ] && { echo "Preencha todas as variáveis no topo do arquivo."; exit 1; }
}

validar_prerequisitos() {
    command -v aws    &>/dev/null || { log "❌ AWS CLI não encontrado."; exit 1; }
    command -v docker &>/dev/null || { log "❌ Docker não encontrado.";  exit 1; }

    docker volume inspect "$DOCKER_VOLUME_BD" &>/dev/null \
        || { log "❌ Volume $DOCKER_VOLUME_BD não encontrado no Docker."; exit 1; }

    docker inspect -f '{{.State.Running}}' "$CONTAINER_BANCO" 2>/dev/null \
        | grep -q true \
        || { log "❌ Container $CONTAINER_BANCO não está rodando."; exit 1; }

    # FIX: verifica espaço disponível no diretório de dump (alerta se < 1GB)
    local ESPACO_MB
    ESPACO_MB=$(df -m "$DUMP_DIR" | tail -1 | awk '{print $4}')
    if [ "$ESPACO_MB" -lt 1024 ]; then
        log "⚠️  Espaço disponível em $DUMP_DIR: ${ESPACO_MB}MB — abaixo de 1GB. Prosseguindo com cautela."
    fi
}

# ==============================================================================
# ETAPAS
# ==============================================================================

fazer_dump() {
    log "Executando pg_dumpall no container $CONTAINER_BANCO..."
    docker exec "$CONTAINER_BANCO" pg_dumpall -U "$DB_USER" | gzip > "$ARQUIVO_LOCAL"

    # FIX: valida integridade do arquivo antes de continuar
    log "Validando integridade do arquivo comprimido..."
    if ! gzip -t "$ARQUIVO_LOCAL" 2>/dev/null; then
        log "❌ Arquivo corrompido detectado — abortando envio ao S3."
        rm -f "$ARQUIVO_LOCAL"
        exit 1
    fi

    local TAMANHO
    TAMANHO=$(du -sh "$ARQUIVO_LOCAL" | cut -f1)
    log "✅ Dump concluído e íntegro — tamanho comprimido: $TAMANHO"
}

enviar_s3() {
    log "Enviando para $ARQUIVO_S3 ..."
    aws s3 cp "$ARQUIVO_LOCAL" "$ARQUIVO_S3" \
        --region "$AWS_REGION" \
        --storage-class STANDARD_IA
    log "✅ Upload concluído."
    rm -f "$ARQUIVO_LOCAL"
}

limpar_backups_antigos() {
    local DATA_LIMITE
    DATA_LIMITE=$(date -d "${RETENCAO_DIAS} days ago" '+%Y-%m-%d')
    log "Removendo backups anteriores a $DATA_LIMITE no bucket..."

    local REMOVIDOS=0
    while IFS= read -r LINHA; do
        local DATA_ARQUIVO NOME_ARQUIVO
        DATA_ARQUIVO=$(echo "$LINHA" | awk '{print $1}')
        NOME_ARQUIVO=$(echo "$LINHA" | awk '{print $4}')

        [[ -z "$NOME_ARQUIVO" ]] && continue

        if [[ "$DATA_ARQUIVO" < "$DATA_LIMITE" ]]; then
            log "   🗑️  Removendo: ${S3_BUCKET}/${NOME_ARQUIVO##*/} ($DATA_ARQUIVO)"
            aws s3 rm "${S3_BUCKET}/${NOME_ARQUIVO##*/}" --region "$AWS_REGION"
            REMOVIDOS=$((REMOVIDOS + 1))
        fi
    done < <(aws s3 ls "${S3_BUCKET}/" --region "$AWS_REGION" 2>/dev/null || true)

    [ "$REMOVIDOS" -eq 0 ] \
        && log "Nenhum backup antigo encontrado." \
        || log "✅ $REMOVIDOS arquivo(s) removido(s) do bucket."
}

# ==============================================================================
# EXECUÇÃO
# ==============================================================================

validar_variaveis

export AWS_ACCESS_KEY_ID
export AWS_SECRET_ACCESS_KEY
export AWS_DEFAULT_REGION="$AWS_REGION"

log "=========================================="
log "🗄️  Backup iniciado"
log "   Container  : $CONTAINER_BANCO"
log "   Volume     : $DOCKER_VOLUME_BD"
log "   Destino    : $ARQUIVO_S3"
log "   Dump dir   : $DUMP_DIR"
log "=========================================="

validar_prerequisitos
fazer_dump
enviar_s3
limpar_backups_antigos

RESUMO="container=$CONTAINER_BANCO arquivo=$(basename "$ARQUIVO_S3") host=$(hostname)"
notificar_ok "$RESUMO"

log "=========================================="
log "✅ Backup finalizado com sucesso."
log "=========================================="

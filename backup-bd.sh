#!/bin/bash
set -euo pipefail

# ==============================================================================
# ⚠️  ATENÇÃO — ARQUIVO SENSÍVEL
# NUNCA faça commit deste arquivo. Contém credenciais AWS.
# Guarde localmente em: /clientes/<nome-cliente>/backup-bd.sh
# ==============================================================================

# ------------------------------------------------------------------------------
# 🛠️  CONFIGURAÇÕES — ALTERE AQUI PARA CADA NOVO DEPLOY
# ------------------------------------------------------------------------------
AWS_ACCESS_KEY_ID="SUA_ACCESS_KEY_AQUI"
AWS_SECRET_ACCESS_KEY="SUA_SECRET_KEY_AQUI"
AWS_REGION="us-east-1"
S3_BUCKET="s3://nome-do-seu-bucket/backups"

CONTAINER_BANCO="bd_producao"
DOCKER_VOLUME_BD="dados_postgres"
DB_USER="admin_usuario"

RETENCAO_DIAS=7

# ==============================================================================
# INICIALIZAÇÃO
# ==============================================================================
LOG="/var/log/backup_banco.log"
DATA=$(date '+%Y-%m-%d_%H-%M-%S')
ARQUIVO_LOCAL="/tmp/backup_${DATA}.sql.gz"
ARQUIVO_S3="${S3_BUCKET}/backup_${DATA}.sql.gz"

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }
erro() { log "❌ ERRO na linha $1: $2"; rm -f "$ARQUIVO_LOCAL"; exit 1; }
trap 'erro $LINENO "$BASH_COMMAND"' ERR

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
}

# ==============================================================================
# ETAPAS
# ==============================================================================
fazer_dump() {
    log "Executando pg_dumpall no container $CONTAINER_BANCO..."
    docker exec "$CONTAINER_BANCO" pg_dumpall -U "$DB_USER" | gzip > "$ARQUIVO_LOCAL"
    local TAMANHO
    TAMANHO=$(du -sh "$ARQUIVO_LOCAL" | cut -f1)
    log "✅ Dump concluído — tamanho comprimido: $TAMANHO"
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
            log "  🗑️  Removendo: ${S3_BUCKET}/${NOME_ARQUIVO##*/} ($DATA_ARQUIVO)"
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
log "   Container : $CONTAINER_BANCO"
log "   Volume    : $DOCKER_VOLUME_BD"
log "   Destino   : $ARQUIVO_S3"
log "=========================================="

validar_prerequisitos
fazer_dump
enviar_s3
limpar_backups_antigos

log "=========================================="
log "✅ Backup finalizado com sucesso."
log "=========================================="
#!/bin/bash
set -euo pipefail

# ==============================================================================
# ⚠️  ATENÇÃO — ARQUIVO SENSÍVEL
# NUNCA faça commit deste arquivo. Contém credenciais AWS.
# Guarde localmente em: /clientes/<nome-cliente>/restore-bd.sh
# ==============================================================================

# ------------------------------------------------------------------------------
# 🛠️  CONFIGURAÇÕES — ALTERE AQUI PARA CADA DEPLOY
# ------------------------------------------------------------------------------
AWS_ACCESS_KEY_ID="SUA_ACCESS_KEY_AQUI"
AWS_SECRET_ACCESS_KEY="SUA_SECRET_KEY_AQUI"
AWS_REGION="us-east-1"
S3_BUCKET="s3://nome-do-seu-bucket/backups"

CONTAINER_BANCO="bd_producao"
DOCKER_VOLUME="dados_postgres"
DB_USER="admin_usuario"
POSTGRES_PASSWORD="senha_segura"
POSTGRES_DB="nome_do_banco"

COMPOSE_DIR="/app/infra"
POSTGRES_IMAGE="postgres:16"

# ==============================================================================
# INICIALIZAÇÃO
# ==============================================================================
LOG="/var/log/restore_banco.log"
ARQUIVO_LOCAL="/tmp/restore_$(date '+%Y-%m-%d_%H-%M-%S').sql.gz"
CONTAINER_TEMP="${CONTAINER_BANCO}_restore"

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }
erro() {
    log "❌ ERRO na linha $1: $2"
    rm -f "$ARQUIVO_LOCAL"
    docker rm -f "$CONTAINER_TEMP" 2>/dev/null || true
    exit 1
}
trap 'erro $LINENO "$BASH_COMMAND"' ERR

# ==============================================================================
# VALIDAÇÕES
# ==============================================================================
validar_root() {
    [ "$(id -u)" -eq 0 ] || { echo "❌ Rode como root: sudo bash restore-bd.sh"; exit 1; }
}

validar_variaveis() {
    local ERRO=0
    for VAR in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_REGION S3_BUCKET \
               CONTAINER_BANCO DOCKER_VOLUME DB_USER POSTGRES_PASSWORD \
               POSTGRES_DB COMPOSE_DIR; do
        local VALOR="${!VAR}"
        if [ -z "$VALOR" ] || [[ "$VALOR" == *"_AQUI"* ]] || [[ "$VALOR" == *"nome-do-seu"* ]]; then
            echo "❌ Variável $VAR não preenchida."
            ERRO=1
        fi
    done
    [ "$ERRO" -eq 1 ] && { echo "Preencha todas as variáveis no topo do arquivo."; exit 1; }
}

validar_prerequisitos() {
    command -v aws    &>/dev/null || { log "❌ AWS CLI não encontrado.";  exit 1; }
    command -v docker &>/dev/null || { log "❌ Docker não encontrado.";   exit 1; }

    [ -f "$COMPOSE_DIR/docker-compose.yml" ] || {
        log "❌ docker-compose.yml não encontrado em $COMPOSE_DIR"
        exit 1
    }
}

# ==============================================================================
# ETAPAS
# ==============================================================================
buscar_backup_recente() {
    log "Buscando backup mais recente em $S3_BUCKET ..."

    ARQUIVO_RECENTE=$(aws s3 ls "${S3_BUCKET}/" \
        --region "$AWS_REGION" \
        | grep "\.sql\.gz" \
        | sort \
        | tail -1 \
        | awk '{print $4}')

    [ -n "$ARQUIVO_RECENTE" ] || { log "❌ Nenhum backup encontrado no bucket."; exit 1; }

    log "✅ Backup mais recente: $ARQUIVO_RECENTE"
}

confirmar_operacao() {
    echo ""
    echo "  ============================================"
    echo "  Backup a restaurar : $ARQUIVO_RECENTE"
    echo "  Volume Docker      : $DOCKER_VOLUME"
    echo "  Compose dir        : $COMPOSE_DIR"
    echo "  ============================================"
    echo "  ⚠️  O volume $DOCKER_VOLUME será APAGADO e recriado."
    echo "  ⚠️  Esta operação não pode ser desfeita."
    echo ""
    read -rp "  Digite CONFIRMAR para continuar: " CONFIRMACAO
    [ "$CONFIRMACAO" = "CONFIRMAR" ] || { log "Operação cancelada pelo usuário."; exit 0; }
}

parar_containers_e_recriar_volume() {
    log "Parando containers via docker compose..."
    cd "$COMPOSE_DIR" && docker compose down
    log "✅ Containers parados."

    log "Removendo volume $DOCKER_VOLUME..."
    docker volume rm "$DOCKER_VOLUME" 2>/dev/null || true

    docker volume create "$DOCKER_VOLUME"
    log "✅ Volume $DOCKER_VOLUME recriado zerado."
}

subir_container_temporario() {
    # Garante que não existe um container temporário anterior pendurado
    docker rm -f "$CONTAINER_TEMP" 2>/dev/null || true

    log "Subindo container temporário $CONTAINER_TEMP ($POSTGRES_IMAGE)..."
    docker run -d \
        --name "$CONTAINER_TEMP" \
        --volume "${DOCKER_VOLUME}:/var/lib/postgresql/data" \
        --env POSTGRES_USER="$DB_USER" \
        --env POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
        --env POSTGRES_DB="$POSTGRES_DB" \
        "$POSTGRES_IMAGE"

    log "Aguardando Postgres ficar pronto..."
    local TENTATIVAS=0
    until docker exec "$CONTAINER_TEMP" pg_isready -U "$DB_USER" -q 2>/dev/null; do
        TENTATIVAS=$((TENTATIVAS + 1))
        [ "$TENTATIVAS" -ge 30 ] && { log "❌ Postgres não inicializou após 60s."; exit 1; }
        sleep 2
    done
    log "✅ Postgres pronto."
}

baixar_backup() {
    log "Baixando $ARQUIVO_RECENTE do S3..."
    aws s3 cp "${S3_BUCKET}/${ARQUIVO_RECENTE}" "$ARQUIVO_LOCAL" --region "$AWS_REGION"
    log "✅ Download concluído. Tamanho: $(du -sh "$ARQUIVO_LOCAL" | cut -f1)"
}

restaurar_banco() {
    log "Restaurando banco de dados..."
    gunzip -c "$ARQUIVO_LOCAL" \
        | docker exec -i "$CONTAINER_TEMP" psql -U "$DB_USER" -d postgres
    log "✅ Restore concluído."
    rm -f "$ARQUIVO_LOCAL"
}

subir_servicos() {
    log "Removendo container temporário..."
    docker stop "$CONTAINER_TEMP"
    docker rm   "$CONTAINER_TEMP"

    log "Subindo todos os serviços com docker compose..."
    cd "$COMPOSE_DIR" && docker compose up -d
    docker compose ps | tee -a "$LOG"
}

# ==============================================================================
# EXECUÇÃO
# ==============================================================================
validar_root
validar_variaveis

export AWS_ACCESS_KEY_ID
export AWS_SECRET_ACCESS_KEY
export AWS_DEFAULT_REGION="$AWS_REGION"

validar_prerequisitos

log "=========================================="
log "🚨 Restore iniciado"
log "   Container : $CONTAINER_BANCO"
log "   Volume    : $DOCKER_VOLUME"
log "   Bucket    : $S3_BUCKET"
log "=========================================="

buscar_backup_recente
confirmar_operacao
parar_containers_e_recriar_volume
subir_container_temporario
baixar_backup
restaurar_banco
subir_servicos

log ""
log "🎉 =========================================="
log "   RESTORE CONCLUÍDO COM SUCESSO!"
log "   Backup restaurado : $ARQUIVO_RECENTE"
log "   Log               : $LOG"
log "=========================================="
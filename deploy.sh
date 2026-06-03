#!/bin/bash

set -euo pipefail

# ==============================================================================
# 🚀 SCRIPT DE DEPLOY
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

GITHUB_USER="${GITHUB_USER:-Matheus-Sleutjes}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"

# Formato: "nome_pasta|nome_repositorio"
REPOS_LIST="${REPOS_LIST:-}"
 
# Converte a string em array
read -r -a REPOS <<< "$REPOS_LIST"

# ------------------------------------------------------------------------------
# ⚙️ CONFIGURAÇÕES GERAIS
# ------------------------------------------------------------------------------

PASTA_PROJETO="${PASTA_PROJETO:-/app}"
LOG_FILE="${DEPLOY_LOG:-/var/log/deploy.log}"
LOCK_FILE="/tmp/deploy.lock"

# Quantas versões de imagem manter por repo (além da latest)
IMAGENS_A_MANTER="${IMAGENS_A_MANTER:-3}"

# ==============================================================================
# LOCK — impede execuções paralelas
# ==============================================================================

exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    echo "❌ Outro deploy já está em execução (lock: $LOCK_FILE). Abortando."
    exit 1
fi

# ==============================================================================
# VALIDAÇÕES
# ==============================================================================

if [ "$(id -u)" -ne 0 ]; then
    echo "❌ Rode como root: sudo bash deploy.sh"
    exit 1
fi

ERRO_VARS=0
for VAR in GITHUB_USER GITHUB_TOKEN; do
    VALOR="${!VAR}"
    if [ -z "$VALOR" ] || [[ "$VALOR" == *"seu_"* ]] || [[ "$VALOR" == *"_aqui"* ]]; then
        echo "❌ Variável $VAR não foi preenchida."
        ERRO_VARS=1
    fi
done
[ "$ERRO_VARS" -eq 1 ] && exit 1

command -v git    &>/dev/null || { echo "❌ git não encontrado.";    exit 1; }
command -v docker &>/dev/null || { echo "❌ Docker não encontrado."; exit 1; }

# ==============================================================================
# FUNÇÕES
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

clone_repo() {
    local PASTA="$1"
    local REPO="$2"
    local DESTINO="$PASTA_PROJETO/$PASTA"

    # FIX: trap garante que o ASKPASS é removido mesmo em crash
    local ASKPASS
    ASKPASS=$(mktemp)
    trap "rm -f '$ASKPASS'" EXIT
    chmod 700 "$ASKPASS"
    printf '#!/bin/bash\necho "%s"\n' "$GITHUB_TOKEN" > "$ASKPASS"

    GIT_ASKPASS="$ASKPASS" \
    GIT_USERNAME="$GITHUB_USER" \
    git clone "https://github.com/${GITHUB_USER}/${REPO}.git" "$DESTINO"

    rm -f "$ASKPASS"
    trap - EXIT

    cd "$DESTINO" && git remote set-url origin "https://github.com/${GITHUB_USER}/${REPO}.git"
}

pull_repo() {
    local DESTINO="$1"
    cd "$DESTINO"

    # FIX: avisa sobre arquivos modificados localmente antes de sobrescrever
    local MODIFICADOS
    MODIFICADOS=$(git status --porcelain 2>/dev/null | wc -l)
    if [ "$MODIFICADOS" -gt 0 ]; then
        log "⚠️  $DESTINO tem $MODIFICADOS arquivo(s) modificado(s) localmente — serão sobrescritos pelo reset."
        git status --short | tee -a "$LOG_FILE"
    fi

    git fetch origin
    git reset --hard "origin/$(git rev-parse --abbrev-ref HEAD)"
}

# Retorna a IMAGE_VERSIONED anterior de um repo (para rollback em caso de falha)
imagem_anterior() {
    local PASTA="$1"
    docker images --format "{{.Repository}}:{{.Tag}}" \
        | grep "^${PASTA}:" \
        | grep -v ":latest" \
        | sort -r \
        | sed -n '2p'  # a mais recente é a que acabou de ser buildada, a segunda é a anterior
}

verificar_container() {
    local PASTA="$1"
    local CONTAINER_STATUS
    CONTAINER_STATUS=$(docker inspect --format='{{.State.Status}}' "$PASTA" 2>/dev/null || echo "not_found")

    if [ "$CONTAINER_STATUS" = "not_found" ]; then
        log "⚠️  Container $PASTA não encontrado após o deploy."
        return 1
    fi

    if [ "$CONTAINER_STATUS" != "running" ]; then
        log "❌ Container $PASTA está com status: $CONTAINER_STATUS"
        return 1
    fi

    log "✅ Container $PASTA está running."
    return 0
}

limpar_imagens_antigas() {
    local PASTA="$1"
    log "Limpando imagens antigas de $PASTA (mantendo as últimas $IMAGENS_A_MANTER versões)..."

    local IMAGENS_VERSIONADAS
    mapfile -t IMAGENS_VERSIONADAS < <(
        docker images --format "{{.Repository}}:{{.Tag}}" \
            | grep "^${PASTA}:" \
            | grep -v ":latest" \
            | sort -r
    )

    local TOTAL="${#IMAGENS_VERSIONADAS[@]}"
    if [ "$TOTAL" -le "$IMAGENS_A_MANTER" ]; then
        log "  $TOTAL imagem(ns) — dentro do limite de $IMAGENS_A_MANTER. Nada removido."
        return
    fi

    local REMOVIDAS=0
    for i in "${!IMAGENS_VERSIONADAS[@]}"; do
        if [ "$i" -ge "$IMAGENS_A_MANTER" ]; then
            log "  🗑️  Removendo: ${IMAGENS_VERSIONADAS[$i]}"
            docker rmi "${IMAGENS_VERSIONADAS[$i]}" 2>/dev/null || true
            REMOVIDAS=$((REMOVIDAS + 1))
        fi
    done
    log "  ✅ $REMOVIDAS imagem(ns) antiga(s) removida(s)."
}

# ==============================================================================

log "=========================================="
log "🚀 Iniciando deploy"

mkdir -p "$PASTA_PROJETO"

# ==============================================================================
step "[1/3] Clonando / atualizando repositórios"
# ==============================================================================

for REPO_ENTRY in "${REPOS[@]}"; do
    PASTA="${REPO_ENTRY%%|*}"
    REPO="${REPO_ENTRY##*|}"
    DESTINO="$PASTA_PROJETO/$PASTA"

    if [ -d "$DESTINO/.git" ]; then
        log "📁 $PASTA já existe — atualizando..."
        pull_repo "$DESTINO"
    else
        log "📥 Clonando $REPO → $DESTINO"
        clone_repo "$PASTA" "$REPO"
    fi

    COMMIT=$(cd "$DESTINO" && git log -1 --pretty='%h — %s (%ar)')
    log "✅ $PASTA pronto. Commit: $COMMIT"
done

# ==============================================================================
step "[2/3] Build das imagens via .cicd/build-prod.sh"
# ==============================================================================

DEPLOY_VERSION=$(date '+%Y%m%d-%H%M%S')
export DEPLOY_VERSION

log "Versão do deploy: $DEPLOY_VERSION"

BUILD_ERROS=0
declare -A IMAGEM_ANTERIOR_MAP  # guarda imagem anterior de cada repo para rollback

for REPO_ENTRY in "${REPOS[@]}"; do
    PASTA="${REPO_ENTRY%%|*}"
    DESTINO="$PASTA_PROJETO/$PASTA"
    BUILD_SCRIPT="$DESTINO/.cicd/build-prod.sh"

    if [ ! -f "$BUILD_SCRIPT" ]; then
        log "⏭️  $PASTA — .cicd/build-prod.sh não encontrado, pulando build."
        continue
    fi

    # Salva a imagem atual antes de buildar (para rollback automático)
    IMAGEM_ANTERIOR_MAP["$PASTA"]=$(imagem_anterior "$PASTA")

    log "🔨 Buildando $PASTA (versão: $DEPLOY_VERSION)..."

    export IMAGE_NAME="$PASTA"
    export IMAGE_TAG="$DEPLOY_VERSION"
    export IMAGE_LATEST="${PASTA}:latest"
    export IMAGE_VERSIONED="${PASTA}:${DEPLOY_VERSION}"

    if bash "$BUILD_SCRIPT"; then
        log "✅ Build de $PASTA concluído → imagem: $IMAGE_VERSIONED"
    else
        log "❌ ERRO no build de $PASTA"
        BUILD_ERROS=$((BUILD_ERROS + 1))
    fi
done

if [ "$BUILD_ERROS" -gt 0 ]; then
    log "❌ $BUILD_ERROS build(s) falharam. Deploy interrompido."
    exit 1
fi

log "Imagens Docker após o build:"
docker images --filter "dangling=false" \
    --format "  {{.Repository}}:{{.Tag}} — {{.Size}} — criada {{.CreatedSince}}" \
    | grep -v "<none>" | tee -a "$LOG_FILE" || true

# ==============================================================================
step "[3/3] Recriando containers via .cicd/deploy-prod.sh"
# ==============================================================================

DEPLOY_ERROS=0

for REPO_ENTRY in "${REPOS[@]}"; do
    PASTA="${REPO_ENTRY%%|*}"
    DESTINO="$PASTA_PROJETO/$PASTA"
    DEPLOY_SCRIPT="$DESTINO/.cicd/deploy-prod.sh"

    if [ ! -f "$DEPLOY_SCRIPT" ]; then
        log "⏭️  $PASTA — .cicd/deploy-prod.sh não encontrado, pulando."
        continue
    fi

    log "♻️  Recriando containers de $PASTA..."

    cd "$DESTINO"

    export IMAGE_NAME="$PASTA"
    export IMAGE_TAG="$DEPLOY_VERSION"
    export IMAGE_LATEST="${PASTA}:latest"
    export IMAGE_VERSIONED="${PASTA}:${DEPLOY_VERSION}"

    if bash "$DEPLOY_SCRIPT"; then
        log "✅ Containers de $PASTA no ar."

        # Verifica se o container ficou running após o deploy
        if ! verificar_container "$PASTA"; then
            IMAGEM_VOLTA="${IMAGEM_ANTERIOR_MAP[$PASTA]:-}"
            if [ -n "$IMAGEM_VOLTA" ]; then
                log "🔁 Iniciando rollback de $PASTA → $IMAGEM_VOLTA"
                export IMAGE_VERSIONED="$IMAGEM_VOLTA"
                export IMAGE_TAG="${IMAGEM_VOLTA##*:}"
                if bash "$DEPLOY_SCRIPT"; then
                    log "✅ Rollback de $PASTA concluído. Versão anterior restaurada."
                else
                    log "❌ Rollback de $PASTA também falhou! Intervenção manual necessária."
                fi
            else
                log "⚠️  Sem imagem anterior disponível para rollback de $PASTA."
            fi
            DEPLOY_ERROS=$((DEPLOY_ERROS + 1))
        fi
    else
        log "❌ ERRO no deploy de $PASTA"

        # FIX: rollback automático em caso de falha no deploy
        IMAGEM_VOLTA="${IMAGEM_ANTERIOR_MAP[$PASTA]:-}"
        if [ -n "$IMAGEM_VOLTA" ]; then
            log "🔁 Iniciando rollback de $PASTA → $IMAGEM_VOLTA"
            export IMAGE_VERSIONED="$IMAGEM_VOLTA"
            export IMAGE_TAG="${IMAGEM_VOLTA##*:}"
            if bash "$DEPLOY_SCRIPT"; then
                log "✅ Rollback de $PASTA concluído. Versão anterior restaurada."
            else
                log "❌ Rollback de $PASTA também falhou! Intervenção manual necessária."
            fi
        fi

        DEPLOY_ERROS=$((DEPLOY_ERROS + 1))
    fi

    # FIX: limpeza de imagens versionadas antigas por repo
    limpar_imagens_antigas "$PASTA"
done

# Remove imagens sem tag (dangling) geradas pelos builds
log "Limpando imagens dangling..."
docker image prune -f | tee -a "$LOG_FILE" || true

if [ "$DEPLOY_ERROS" -gt 0 ]; then
    log "❌ $DEPLOY_ERROS deploy(s) falharam. Verifique o log: $LOG_FILE"
    exit 1
fi

# ==============================================================================
log ""
log "🎉 =================================================="
log "   DEPLOY CONCLUÍDO!"
log "   Versão: $DEPLOY_VERSION"
log "   Log:    $LOG_FILE"
log "=================================================="

#!/bin/bash
set -euo pipefail

# ==============================================================================
# 🚀 SCRIPT DE DEPLOY
# ==============================================================================

# ------------------------------------------------------------------------------
# 🛠️  CONFIGURAÇÕES — CARREGADAS DO .ENV NA RAIZ
# ------------------------------------------------------------------------------
if [ -f "$(dirname "$0")/.env" ]; then
    export $(grep -v '^#' "$(dirname "$0")/.env" | xargs)
elif [ -f ".env" ]; then
    export $(grep -v '^#' .env | xargs)
fi

GITHUB_USER="${GITHUB_USER:-Matheus-Sleutjes}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"

# Formato: "nome_pasta|nome_repositorio"
declare -a REPOS=(
    "api|ApiTesteDeploy"
    #"frontend|nome-repo-frontend"
    #"infra|nome-repo-infra"
)

# ------------------------------------------------------------------------------
# ⚙️  CONFIGURAÇÕES GERAIS
# ------------------------------------------------------------------------------
PASTA_PROJETO="${PASTA_PROJETO:-/app}"
LOG_FILE="${DEPLOY_LOG:-/var/log/deploy.log}"

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
    echo "  $*"
    echo "======================================================================="
    log "STEP: $*"
}

clone_repo() {
    local PASTA="$1"
    local REPO="$2"
    local DESTINO="$PASTA_PROJETO/$PASTA"

    local ASKPASS
    ASKPASS=$(mktemp)
    chmod 700 "$ASKPASS"
    printf '#!/bin/bash\necho "%s"\n' "$GITHUB_TOKEN" > "$ASKPASS"

    GIT_ASKPASS="$ASKPASS" \
    GIT_USERNAME="$GITHUB_USER" \
        git clone "https://github.com/${GITHUB_USER}/${REPO}.git" "$DESTINO"

    rm -f "$ASKPASS"

    cd "$DESTINO" && git remote set-url origin "https://github.com/${GITHUB_USER}/${REPO}.git"
}

pull_repo() {
    local DESTINO="$1"
    cd "$DESTINO"
    git fetch origin
    git reset --hard origin/$(git rev-parse --abbrev-ref HEAD)
}

# ==============================================================================
log "=========================================="
log "🚀 Iniciando deploy"

mkdir -p "$PASTA_PROJETO"

# ==============================================================================
step "[1/3] Clonando repositórios"
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

# Versão global do deploy usada como tag base de todas as imagens
# Formato: YYYYMMDD-HHMMSS — garante ordenação cronológica e unicidade
DEPLOY_VERSION=$(date '+%Y%m%d-%H%M%S')
export DEPLOY_VERSION

log "Versão do deploy: $DEPLOY_VERSION"

BUILD_ERROS=0

for REPO_ENTRY in "${REPOS[@]}"; do
    PASTA="${REPO_ENTRY%%|*}"
    DESTINO="$PASTA_PROJETO/$PASTA"
    BUILD_SCRIPT="$DESTINO/.cicd/build-prod.sh"

    if [ ! -f "$BUILD_SCRIPT" ]; then
        log "⏭️  $PASTA — .cicd/build-prod.sh não encontrado, pulando build."
        continue
    fi

    log "🔨 Buildando $PASTA (versão: $DEPLOY_VERSION)..."

    # Exporta variáveis úteis para o build-prod.sh de cada repo
    # O script pode usar IMAGE_NAME e IMAGE_TAG livremente
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

# Registra no log quais imagens foram criadas neste deploy
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

    # As mesmas variáveis do passo 2 ficam disponíveis para o deploy-prod.sh
    # IMAGE_NAME, IMAGE_TAG, IMAGE_VERSIONED, IMAGE_LATEST, DEPLOY_VERSION
    export IMAGE_NAME="$PASTA"
    export IMAGE_TAG="$DEPLOY_VERSION"
    export IMAGE_LATEST="${PASTA}:latest"
    export IMAGE_VERSIONED="${PASTA}:${DEPLOY_VERSION}"

    if bash "$DEPLOY_SCRIPT"; then
        log "✅ Containers de $PASTA no ar."
    else
        log "❌ ERRO no deploy de $PASTA"
        DEPLOY_ERROS=$((DEPLOY_ERROS + 1))
    fi
done

if [ "$DEPLOY_ERROS" -gt 0 ]; then
    log "❌ $DEPLOY_ERROS deploy(s) falharam. Verifique o log: $LOG_FILE"
    exit 1
fi

# Remove imagens antigas sem tag (dangling) geradas pelos builds anteriores
log "Limpando imagens antigas sem tag..."
docker image prune -f | tee -a "$LOG_FILE" || true
# ==============================================================================
log ""
log "🎉 =================================================="
log "   DEPLOY CONCLUÍDO!"
log "   Versão: $DEPLOY_VERSION"
log "   Log:    $LOG_FILE"
log "=================================================="

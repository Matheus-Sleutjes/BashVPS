#!/bin/bash
# .cicd/deploy-prod.sh

# Carrega .env da raiz se existir
if [ -f "$(dirname "$0")/../.env" ]; then
    export $(grep -v '^#' "$(dirname "$0")/../.env" | xargs)
fi

# Remove o container existente
docker rm -f backend 2>/dev/null || true

# Sobe o novo a partir da imagem versionada criada no build
docker run -d \
    --name backend \
    --restart always \
    --network minha-rede \
    -p 3000:3000 \
    --env-file /app/backend/.env \
    "${IMAGE_VERSIONED}"
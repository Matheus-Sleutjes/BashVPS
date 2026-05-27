#!/bin/bash
# .cicd/deploy-prod.sh

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
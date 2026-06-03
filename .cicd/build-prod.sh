#!/bin/bash
# .cicd/build-prod.sh

# Carrega .env da raiz se existir
if [ -f "$(dirname "$0")/../.env" ]; then
    export $(grep -v '^#' "$(dirname "$0")/../.env" | xargs)
fi

docker build \
    -t "${IMAGE_VERSIONED}" \
    -t "${IMAGE_LATEST}" \
    -f Dockerfile.prod \
    .
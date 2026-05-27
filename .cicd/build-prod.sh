#!/bin/bash
# .cicd/build-prod.sh
docker build \
    -t "${IMAGE_VERSIONED}" \
    -t "${IMAGE_LATEST}" \
    -f Dockerfile.prod \
    .
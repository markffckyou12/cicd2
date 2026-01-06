#!/bin/bash
set -euo pipefail

TRIVY_CONTAINER_NAME="trivy-server-local"

echo "--- Initializing Persistent Trivy Server ---"

# 1. Clean up existing container if it exists
if [ "$(docker ps -aq -f name=${TRIVY_CONTAINER_NAME})" ]; then
    echo "Stopping and removing old Trivy server..."
    docker rm -f ${TRIVY_CONTAINER_NAME} > /dev/null
fi

# 2. Ensure local cache directory exists
mkdir -p $HOME/.cache/trivy

# 3. Start the server
echo "Starting Trivy Server on port 8080..."
docker run -d \
  --name ${TRIVY_CONTAINER_NAME} \
  --restart always \
  -p 8080:8080 \
  -v $HOME/.cache/trivy:/root/.cache/trivy \
  aquasec/trivy:latest server --listen 0.0.0.0:8080

# 4. Wait for the server to be healthy
echo "Waiting for vulnerability DB to be ready..."
until curl -s http://localhost:8080/healthz > /dev/null; do
  sleep 2
done

echo "--- Trivy Server is UP and READY ---"

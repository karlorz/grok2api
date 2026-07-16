#!/usr/bin/env bash
# First-time (or full) deploy to kr01: build, upload, config init, systemd, Caddy.
# For routine binary/frontend rollouts use: scripts/update.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
cd "$ROOT_DIR"

echo "==== Step 1: Building ARM64 release bundle locally ===="
make build-arm64

LOCAL_SHA="$(git rev-parse HEAD)"
resolve_git_branch

echo "==== Step 2: Preparing remote host target directory ===="
ssh "$HOST" "mkdir -p '${TARGET_DIR}/data' && systemctl stop '${SERVICE_NAME}' || true"

echo "==== Step 3: Uploading binary, config, and frontend files ===="
upload_release_bundle

echo "==== Step 4: Setting up remote config.yaml ===="
ssh "$HOST" "
  if [ ! -f ${TARGET_DIR}/config.yaml ]; then
    echo 'No config.yaml found on host. Initializing with default example...'
    cp ${TARGET_DIR}/config.example.yaml ${TARGET_DIR}/config.yaml
  fi

  if grep -q 'replace-with' ${TARGET_DIR}/config.yaml; then
    echo 'Placeholders detected in config.yaml. Generating random secrets...'
    sed -i 's|staticPath: \".*\"|staticPath: \"${TARGET_DIR}/frontend/dist\"|g' ${TARGET_DIR}/config.yaml
    sed -i 's|path: \"\./data/backend\.db\"|path: \"${TARGET_DIR}/data/backend.db\"|g' ${TARGET_DIR}/config.yaml
    sed -i 's|path: \"\./data/media\"|path: \"${TARGET_DIR}/data/media\"|g' ${TARGET_DIR}/config.yaml

    JWT_SECRET=\$(openssl rand -hex 32)
    ENC_KEY=\$(openssl rand -base64 32)
    ADMIN_PASS=\$(openssl rand -base64 16)

    sed -i \"s|jwtSecret: \\\"replace-with-at-least-32-characters\\\"|jwtSecret: \\\"\$JWT_SECRET\\\"|g\" ${TARGET_DIR}/config.yaml
    sed -i \"s|credentialEncryptionKey: \\\"replace-with-base64-key\\\"|credentialEncryptionKey: \\\"\$ENC_KEY\\\"|g\" ${TARGET_DIR}/config.yaml
    sed -i \"s|password: \\\"replace-with-a-strong-password\\\"|password: \\\"\$ADMIN_PASS\\\"|g\" ${TARGET_DIR}/config.yaml
    chmod 600 ${TARGET_DIR}/config.yaml

    echo 'Initialized config.yaml with random secrets:'
    echo \"- Admin Username: admin\"
    echo \"- Admin Password: \$ADMIN_PASS\"
    echo 'Please save these credentials!'
  fi
"

echo "==== Step 5: Installing Systemd Service ===="
scp ./deployment/grok2api.service "$HOST:/tmp/grok2api.service"
ssh "$HOST" "
  mv /tmp/grok2api.service /etc/systemd/system/grok2api.service
  chmod 644 /etc/systemd/system/grok2api.service
  systemctl daemon-reload
  systemctl enable '${SERVICE_NAME}'
  systemctl restart '${SERVICE_NAME}'
"

echo "==== Step 6: Configuring Caddy on ${HOST} ===="
ssh "$HOST" "
  CADDYFILE=/etc/caddy/Caddyfile
  DOMAIN='${DOMAIN}'
  LISTEN='${LISTEN}'
  if ! grep -q \"\$DOMAIN\" \"\$CADDYFILE\"; then
    echo 'Appending Caddy proxy settings...'
    printf '\n# Grok2API Gateway\n%s {\n\treverse_proxy %s\n}\n' \"\$DOMAIN\" \"\$LISTEN\" >> \"\$CADDYFILE\"
    systemctl reload caddy
    echo 'Caddy reloaded successfully.'
  else
    echo \"Caddyfile already contains configuration for \$DOMAIN. Skipping.\"
  fi
"

echo "==== Step 7: Stamping deploy meta + verifying ===="
write_deploy_meta "$LOCAL_SHA"
verify_health warn
echo "==== Deployment Completed @ $(git rev-parse --short HEAD) ===="

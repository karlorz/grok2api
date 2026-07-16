#!/usr/bin/env bash
set -euo pipefail

HOST="kr01"
TARGET_DIR="/opt/grok2api"
SERVICE_NAME="grok2api"

echo "==== Step 1: Building ARM64 release bundle locally ===="
make build-arm64

echo "==== Step 2: Preparing remote host target directory ===="
ssh "$HOST" "mkdir -p $TARGET_DIR/data"

echo "==== Step 3: Uploading binary, config, and frontend files ===="
scp ./dist/grok2api "$HOST:$TARGET_DIR/grok2api"
scp ./dist/config.example.yaml "$HOST:$TARGET_DIR/config.example.yaml"
# Stream frontend/ directory via tar over SSH
tar -czf - -C ./dist frontend | ssh "$HOST" "tar -xzf - -C $TARGET_DIR"

echo "==== Step 4: Setting up remote config.yaml ===="
ssh "$HOST" "
  if [ ! -f $TARGET_DIR/config.yaml ]; then
    echo 'No config.yaml found on host. Initializing with default example...'
    cp $TARGET_DIR/config.example.yaml $TARGET_DIR/config.yaml
  fi

  if grep -q 'replace-with' $TARGET_DIR/config.yaml; then
    echo 'Placeholders detected in config.yaml. Generating random secrets...'
    # Update paths in config.yaml
    sed -i 's|staticPath: \".*\"|staticPath: \"$TARGET_DIR/frontend/dist\"|g' $TARGET_DIR/config.yaml
    sed -i 's|path: \"\./data/backend\.db\"|path: \"$TARGET_DIR/data/backend.db\"|g' $TARGET_DIR/config.yaml
    sed -i 's|path: \"\./data/media\"|path: \"$TARGET_DIR/data/media\"|g' $TARGET_DIR/config.yaml
    
    JWT_SECRET=\$(openssl rand -hex 32)
    ENC_KEY=\$(openssl rand -base64 32)
    ADMIN_PASS=\$(openssl rand -base64 16)
    
    sed -i \"s|jwtSecret: \\\".*\\\"|jwtSecret: \\\"\$JWT_SECRET\\\"|g\" $TARGET_DIR/config.yaml
    sed -i \"s|credentialEncryptionKey: \\\".*\\\"|credentialEncryptionKey: \\\"\$ENC_KEY\\\"|g\" $TARGET_DIR/config.yaml
    sed -i \"s|password: \\\".*\\\"|password: \\\"\$ADMIN_PASS\\\"|g\" $TARGET_DIR/config.yaml
    
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
  systemctl enable grok2api
  systemctl restart grok2api
"

echo "==== Step 6: Configuring Caddy on kr01 ===="
ssh "$HOST" '
  CADDYFILE="/etc/caddy/Caddyfile"
  DOMAIN="grok2api.karldigi.dev"
  if ! grep -q "$DOMAIN" "$CADDYFILE"; then
    echo "Appending Caddy proxy settings..."
    printf "\n# Grok2API Gateway\n%s {\n\treverse_proxy 127.0.0.1:8000\n}\n" "$DOMAIN" >> "$CADDYFILE"
    systemctl reload caddy
    echo "Caddy reloaded successfully."
  else
    echo "Caddyfile already contains configuration for $DOMAIN. Skipping Caddyfile modification."
  fi
'

echo "==== Step 7: Verifying deployment ===="
sleep 2
ssh "$HOST" "systemctl status grok2api"
echo "==== Deployment Completed ===="

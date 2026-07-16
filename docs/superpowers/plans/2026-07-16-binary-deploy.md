# Grok2API ARM64 Binary Deployment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create a compilation, packaging, and deployment pipeline to run grok2api natively as a systemd binary service behind Caddy on the ARM64 host `kr01`.

**Architecture:** Use local pnpm and Go toolchains to build frontend static files and a cross-compiled `linux/arm64` backend binary. Upload files to `/opt/grok2api` on `kr01`, configure a Systemd service running as root, and update the Caddyfile to reverse proxy the domain `grok2api.karldigi.dev` to the local port `8000`.

**Tech Stack:** Go 1.26, React (Vite/pnpm), Systemd, Bash, SSH/Rsync, Caddy.

## Global Constraints

*   Target binary architecture must be `linux/arm64`.
*   The systemd service must run as `root` (User) and `root` (Group) with `WorkingDirectory=/opt/grok2api`.
*   Config file path: `/opt/grok2api/config.yaml` with SQLite DB path `/opt/grok2api/data/backend.db`.
*   Caddy subdomain: `grok2api.karldigi.dev` reverse proxying to `127.0.0.1:8000`.
*   Must check if config or service already exists before overwriting, and verify deployments using health checks.

---

### Task 1: Update Makefile with ARM64 Compilation Targets

Add build targets to package the React frontend and Go backend for `linux/arm64`.

**Files:**
*   Modify: `Makefile`

**Interfaces:**
*   Produces: `make build-arm64` command which compiles the frontend and backend, outputs them to `./dist`.

*   [ ] **Step 1: Modify Makefile**
    Add the `build-frontend`, `build-backend-arm64`, and `build-arm64` targets.
    
    Replace `Makefile` content with:
    ```makefile
    .PHONY: run swagger build-frontend build-backend-arm64 build-arm64 clean
    
    CONFIG ?= $(CURDIR)/config.yaml
    
    run:
    	cd backend && GOCACHE=$(CURDIR)/.gocache go run ./cmd/grok2api --config "$(abspath $(CONFIG))" $(RUN_ARGS)
    
    swagger:
    	cd backend && GOCACHE=$(CURDIR)/.gocache go run github.com/swaggo/swag/cmd/swag@v1.16.6 init \
    		-g main.go \
    		-d cmd/grok2api,internal/transport/http \
    		--parseInternal \
    		--output docs \
    		--outputTypes go,json,yaml
    
    build-frontend:
    	cd frontend && pnpm install --frozen-lockfile && pnpm build
    
    build-backend-arm64:
    	cd backend && GOCACHE=$(CURDIR)/.gocache CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath -ldflags="-s -w" -o ../dist/grok2api ./cmd/grok2api
    
    build-arm64: clean build-frontend build-backend-arm64
    	mkdir -p dist/frontend
    	cp -r frontend/dist dist/frontend/dist
    	cp config.example.yaml dist/config.example.yaml
    
    clean:
    	rm -rf dist/
    ```

*   [ ] **Step 2: Test Makefile Targets Locally**
    Run the command:
    ```bash
    make build-arm64
    ```
    Expected output:
    Successful compilation of frontend and backend. Check that the `dist/` directory exists and contains `grok2api` (binary), `config.example.yaml`, and `frontend/dist/` (static directory).

*   [ ] **Step 3: Commit Makefile changes**
    ```bash
    git add Makefile
    git commit -m "build: add build-arm64 target to Makefile"
    ```

---

### Task 2: Create Systemd Service File Template

Create the systemd unit file template for the grok2api service.

**Files:**
*   Create: `deployment/grok2api.service`

*   [ ] **Step 1: Write Systemd Unit File**
    Create `deployment/grok2api.service` with:
    ```ini
    [Unit]
    Description=Grok2API Gateway
    Wants=network-online.target
    After=network-online.target
    
    [Service]
    Type=simple
    User=root
    Group=root
    WorkingDirectory=/opt/grok2api
    ExecStart=/opt/grok2api/grok2api --config /opt/grok2api/config.yaml --listen 127.0.0.1:8000
    Restart=on-failure
    RestartSec=5s
    NoNewPrivileges=true
    PrivateTmp=true
    ProtectHome=true
    ProtectSystem=full
    ReadWritePaths=/opt/grok2api
    
    [Install]
    WantedBy=multi-user.target
    ```

*   [ ] **Step 2: Verify File Creation**
    Ensure the file exists:
    ```bash
    cat deployment/grok2api.service
    ```

*   [ ] **Step 3: Commit Systemd template**
    ```bash
    git add deployment/grok2api.service
    git commit -m "deploy: add systemd service unit template"
    ```

---

### Task 3: Create Deployment Automation Script

Create the `scripts/deploy.sh` script to automate deployment and configuration on `kr01`.

**Files:**
*   Create: `scripts/deploy.sh`

*   [ ] **Step 1: Write Deployment Script**
    Create `scripts/deploy.sh` with the following content:
    ```bash
    #!/usr/bin/env bash
    set -euo pipefail
    
    HOST="kr01"
    TARGET_DIR="/opt/grok2api"
    SERVICE_NAME="grok2api"
    
    echo "==== Step 1: Building ARM64 release bundle locally ===="
    make build-arm64
    
    echo "==== Step 2: Preparing remote host target directory ===="
    ssh "$HOST" "mkdir -p $TARGET_DIR/data"
    
    echo "==== Step 3: Uploading binary and frontend files ===="
    # Rsync the compiled binary and frontend files to the host
    rsync -avz --progress ./dist/grok2api "$HOST:$TARGET_DIR/grok2api"
    rsync -avz --progress --delete ./dist/frontend/ "$HOST:$TARGET_DIR/frontend/"
    
    echo "==== Step 4: Setting up remote config.yaml ===="
    # Check if config.yaml exists on host. If not, copy config.example.yaml
    ssh "$HOST" "
      if [ ! -f $TARGET_DIR/config.yaml ]; then
        echo 'No config.yaml found on host. Initializing with default example...'
        cp $TARGET_DIR/grok2api/config.example.yaml $TARGET_DIR/config.yaml || cp $TARGET_DIR/config.example.yaml $TARGET_DIR/config.yaml
        # Update static frontend path to point to /opt/grok2api/frontend/dist
        sed -i 's|staticPath: \".*\"|staticPath: \"$TARGET_DIR/frontend/dist\"|g' $TARGET_DIR/config.yaml
        sed -i 's|path: \"\./data/backend\.db\"|path: \"$TARGET_DIR/data/backend.db\"|g' $TARGET_DIR/config.yaml
        sed -i 's|path: \"\./data/media\"|path: \"$TARGET_DIR/data/media\"|g' $TARGET_DIR/config.yaml
        echo 'Initialized config.yaml. Please edit secrets on the server manually if needed!'
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
    ```

*   [ ] **Step 2: Make Script Executable**
    Run:
    ```bash
    chmod +x scripts/deploy.sh
    ```

*   [ ] **Step 3: Test Script Locally**
    Make sure the script parses correctly with a syntax check:
    ```bash
    bash -n scripts/deploy.sh
    ```

*   [ ] **Step 4: Commit deploy script**
    ```bash
    git add scripts/deploy.sh
    git commit -m "deploy: add automated deployment script for kr01"
    ```

---

### Task 4: Run Deployment and Verify

Execute the deployment process to push the builds to `kr01` and verify.

**Interfaces:**
*   Consumes: `scripts/deploy.sh`

*   [ ] **Step 1: Execute deploy script**
    Run the deployment script:
    ```bash
    ./scripts/deploy.sh
    ```
    Expected output:
    1. Local compilation succeeds.
    2. Files are successfully uploaded to `kr01`.
    3. Systemd service starts on `kr01`.
    4. Caddy configuration is appended and Caddy is reloaded.
    5. Service status output from Systemd shows `active (running)`.

*   [ ] **Step 2: Perform Remote Health Checks**
    Verify the service is listening locally on `kr01` port `8000`:
    ```bash
    ssh kr01 "curl -i http://127.0.0.1:8000/healthz"
    ```
    Expected output: `HTTP/1.1 200 OK` (or JSON health status).

*   [ ] **Step 3: Perform External Caddy Proxy Health Check**
    Test the service via Caddy proxy from the local mac machine:
    ```bash
    curl -i https://grok2api.karldigi.dev/healthz
    ```
    Expected output: `HTTP/1.1 200 OK` (with SSL active).

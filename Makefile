.PHONY: run swagger build-frontend build-backend-arm64 build-arm64 clean deploy update status

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
	mkdir -p dist
	cd backend && GOCACHE=$(CURDIR)/.gocache CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath -ldflags="-s -w" -o ../dist/grok2api ./cmd/grok2api

# Sequential targets avoid parallel race between clean and compile.
build-arm64:
	$(MAKE) clean
	$(MAKE) build-frontend
	$(MAKE) build-backend-arm64
	mkdir -p dist/frontend
	cp -r frontend/dist dist/frontend/dist
	cp config.example.yaml dist/config.example.yaml

# First install / full setup on kr01 (config, systemd, Caddy). Stamps .deploy-meta.
deploy:
	./scripts/deploy.sh

# Fetch origin, compare SHAs, pull if behind, rebuild, roll out. Shared helpers in scripts/common.sh.
# FORCE=1 always rebuild; PULL=0 skip pull; SYNC_UPSTREAM=1 merge upstream; SKIP_BUILD=1 reuse dist.
update:
	./scripts/update.sh

# Read-only probe: local/remote/deployed SHA + health. VERBOSE=1 for full systemctl status.
status:
	./scripts/status.sh

clean:
	rm -rf dist/

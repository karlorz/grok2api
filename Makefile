.PHONY: run swagger build-frontend build-backend-arm64 build-arm64 clean deploy update status version-next version-bump version-release

CONFIG ?= $(CURDIR)/config.yaml
# App version for About UI / update checks. Fork scheme: v3.0.2-0 (upstream v3.0.2 + rev).
APP_VERSION := $(shell tr -d '[:space:]' < $(CURDIR)/VERSION 2>/dev/null)
ifeq ($(strip $(APP_VERSION)),)
APP_VERSION := dev
endif
LDFLAGS ?= -s -w -X github.com/chenyme/grok2api/backend/internal/buildinfo.Version=$(APP_VERSION)

run:
	cd backend && GOCACHE=$(CURDIR)/.gocache go run -ldflags="$(LDFLAGS)" ./cmd/grok2api --config "$(abspath $(CONFIG))" $(RUN_ARGS)

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
	@echo "Building backend with APP_VERSION=$(APP_VERSION)"
	cd backend && GOCACHE=$(CURDIR)/.gocache CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath -ldflags="$(LDFLAGS)" -o ../dist/grok2api ./cmd/grok2api

# Sequential targets avoid parallel race between clean and compile.
build-arm64:
	$(MAKE) clean
	$(MAKE) build-frontend
	$(MAKE) build-backend-arm64
	mkdir -p dist/frontend
	cp -r frontend/dist dist/frontend/dist
	cp config.example.yaml dist/config.example.yaml
	cp VERSION dist/VERSION

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

# Fork tags: upstream v3.0.2 → fork v3.0.2-0, v3.0.2-1, ...
#   make version-next              # print next tag
#   make version-bump              # write next into VERSION
#   make version-bump BASE=v3.1.0  # start new series at v3.1.0-0
#   make version-release           # push tag + GitHub Release from VERSION
version-next:
	./scripts/fork-tag.sh --next

version-bump:
	./scripts/fork-tag.sh $(if $(BASE),--base $(BASE)) --write

version-release:
	./scripts/fork-tag.sh --release

clean:
	rm -rf dist/

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

SHELL := /bin/sh
FLUTTER ?= flutter
SQLC_VERSION := v1.31.1
COMPOSE := docker compose --env-file .env -f infra/compose/compose.yaml
.PHONY: env up down logs ps migrate-up migrate-down backend-check mobile-check contracts sqlc smoke identity-test identity-mobile-contract auth-readiness experiences-test experiences-maintenance
env:
	sh scripts/init-env.sh
	sh scripts/init-identity-env.sh
	sh scripts/init-media-env.sh
up: env
	$(COMPOSE) up -d --build --wait --wait-timeout 180
down:
	$(COMPOSE) down
logs:
	$(COMPOSE) logs --tail=100 -f api
ps:
	$(COMPOSE) ps --all
migrate-up:
	$(COMPOSE) run --rm migrate /app/migrate up
migrate-down:
	$(COMPOSE) run --rm migrate /app/migrate down
backend-check:
	cd backend && test -z "$$(gofmt -l cmd internal)" && go vet ./... && go test ./...
mobile-check:
	cd apps/mobile && $(FLUTTER) pub get --enforce-lockfile && $(FLUTTER) analyze && $(FLUTTER) test
contracts:
	cd backend && go run ./cmd/contractcheck
sqlc:
	cd backend && go run github.com/sqlc-dev/sqlc/cmd/sqlc@$(SQLC_VERSION) generate
smoke:
	sh scripts/smoke.sh
identity-test:
	sh scripts/identity-test.sh

identity-mobile-contract:
	FLOW_FLUTTER_CONTRACT_BIN="$(FLUTTER)" FLOW_IDENTITY_TEST_FILTER=TestFlutterIdentityContract sh scripts/identity-test.sh
auth-readiness:
	python3 scripts/auth-readiness.py

experiences-test:
	sh scripts/experiences-test.sh

experiences-maintenance:
	$(COMPOSE) run --rm api /app/experiences-maintenance

SHELL := /bin/sh
FLUTTER ?= $(CURDIR)/flutterw
SQLC_VERSION := v1.31.1
COMPOSE := docker compose --env-file .env -f infra/compose/compose.yaml
MOBILE_COMPOSE := docker compose --env-file .env --env-file .env.mobile.local -f infra/compose/compose.yaml -f infra/compose/mobile-local.yaml
.PHONY: env up down logs ps migrate-up migrate-down backend-check mobile-check contracts sqlc smoke identity-test identity-mobile-contract auth-readiness experiences-test experiences-maintenance mobile-local mobile-local-down experiences-mobile-contract
env:
	sh scripts/init-env.sh
	sh scripts/init-identity-env.sh
	sh scripts/init-media-env.sh
up: env
	$(COMPOSE) up -d --build --wait --wait-timeout 180
mobile-local: env
	python3 scripts/mobile-local.py
	$(MOBILE_COMPOSE) up -d --build --wait --wait-timeout 180
	@echo 'API pronta. Em apps/mobile: ../../flutterw run --release --dart-define-from-file=config/device.local.json'
mobile-local-down:
	$(MOBILE_COMPOSE) down
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

experiences-mobile-contract:
	FLOW_FLUTTER_CONTRACT_BIN="$(FLUTTER)" FLOW_EXPERIENCES_TEST_FILTER=TestFlutterExperiencesContract sh scripts/experiences-test.sh

.PHONY: participation-test participation-mobile-contract
participation-test:
	FLOW_EXPERIENCES_TEST_FILTER=TestParticipation sh scripts/experiences-test.sh

participation-mobile-contract:
	FLOW_FLUTTER_CONTRACT_BIN="$(FLUTTER)" FLOW_EXPERIENCES_TEST_FILTER=TestFlutterParticipationContract sh scripts/experiences-test.sh

experiences-maintenance:
	$(COMPOSE) run --rm api /app/experiences-maintenance

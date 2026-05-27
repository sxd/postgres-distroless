PG_MAJOR ?= 18
IMAGE ?= localhost/postgres-distroless:$(PG_MAJOR)
BAKE_TARGET ?= pg-$(PG_MAJOR)
PLATFORM ?= linux/amd64
KIND_CLUSTER ?= pg-distroless
VERSION ?=
MAJOR ?=

.PHONY: help print build build-local scan-image test-static test-image test-cnpg test-backup-core test-backup-plugin bump-postgres clean-kind

help:
	@printf '%s\n' \
		'Targets:' \
		'  print              Print the resolved docker buildx bake definition' \
		'  build              Build all configured platforms into BuildKit cache' \
		'  build-local        Build and load a local amd64 image for tests' \
		'  scan-image         Scan the local image with Grype' \
		'  test-static        Run shell syntax checks and shellcheck when available' \
		'  test-image         Run image binary and filesystem contract checks' \
		'  test-cnpg          Run the basic CloudNativePG smoke test' \
		'  test-backup-core   Run pg_basebackup smoke test without backup plugin' \
		'  test-backup-plugin Run CNPG-I Barman Cloud plugin backup smoke test' \
		'  bump-postgres      Update one PG major; use MAJOR=18 VERSION=18.x' \
		'  clean-kind         Delete the default kind smoke-test cluster'

print:
	docker buildx bake --print

build:
	docker buildx bake

build-local:
	docker buildx bake $(BAKE_TARGET) --set $(BAKE_TARGET).platform=$(PLATFORM) --set $(BAKE_TARGET).output=type=docker

scan-image:
	grype "$(IMAGE)" --config .grype.yaml --only-fixed --fail-on critical

test-static:
	bash -n scripts/*.sh test/*.sh test/lib/*.sh
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck scripts/*.sh test/*.sh test/lib/*.sh; \
	else \
		printf '%s\n' 'shellcheck not found; skipped'; \
	fi

test-image:
	PG_MAJOR="$(PG_MAJOR)" test/check-binaries.sh "$(IMAGE)"
	PG_MAJOR="$(PG_MAJOR)" test/check-no-extras.sh "$(IMAGE)"

test-cnpg:
	PG_MAJOR="$(PG_MAJOR)" IMAGE="$(IMAGE)" KIND_CLUSTER="$(KIND_CLUSTER)" test/smoke.sh

test-backup-core:
	PG_MAJOR="$(PG_MAJOR)" IMAGE="$(IMAGE)" KIND_CLUSTER="$(KIND_CLUSTER)" test/basebackup-smoke.sh

test-backup-plugin:
	PG_MAJOR="$(PG_MAJOR)" IMAGE="$(IMAGE)" KIND_CLUSTER="$(KIND_CLUSTER)" test/backup-smoke.sh

bump-postgres:
	@test -n "$(MAJOR)" && test -n "$(VERSION)" || { printf '%s\n' 'usage: make bump-postgres MAJOR=18 VERSION=18.x' >&2; exit 2; }
	scripts/bump-postgres.sh --major "$(MAJOR)" "$(VERSION)"

clean-kind:
	kind delete cluster --name "$(KIND_CLUSTER)"

.DEFAULT_GOAL := check
.PHONY: check lint test up down smoke logs size scan clean

## check: everything that runs without Docker
check: lint test

## lint: Dockerfile and shell script linting
lint:
	hadolint Dockerfile
	shellcheck scripts/*.sh
	shfmt -i 4 -ci -d scripts/*.sh

## test: application unit tests — no container, no database
test:
	cd app && npm ci --silent && npm test

## up: build and start the stack
up:
	@test -f .env || (echo "no .env — run: cp .env.example .env" && exit 1)
	docker compose up -d --build

## smoke: end-to-end checks against a running stack
smoke:
	./scripts/smoke.sh

## logs: follow the application logs
logs:
	docker compose logs -f app

## size: compare the multi-stage image against a single-stage build
size:
	docker build --target runtime -t stack:multi . >/dev/null
	@printf 'multi-stage: '; docker image inspect stack:multi --format '{{.Size}}' | numfmt --to=iec

## scan: vulnerability scan of the runtime image
scan:
	docker build --target runtime -t stack:scan .
	docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
		aquasec/trivy:latest image --severity HIGH,CRITICAL --ignore-unfixed stack:scan

## down: stop the stack and delete its volume
down:
	docker compose down -v

clean: down
	rm -rf app/node_modules

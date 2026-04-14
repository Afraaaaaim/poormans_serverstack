.PHONY: init-authentik up-authentik down-authentik

init-authentik:
	@echo "→ Creating Authentik database and user..."
	@set -a && . ./authentik/.env && set +a && \
	docker run --rm \
		-e PGPASSWORD=$$PG_ADMIN_PASSWORD \
		postgres:17-alpine \
		psql -h $$PG_HOST -p $$PG_PORT -U $$PG_ADMIN_USER -d $$PG_ADMIN_DB \
		-c "CREATE USER $$PG_USER WITH PASSWORD '$$PG_PASSWORD';" \
		-c "CREATE DATABASE $$PG_DB OWNER $$PG_USER;" \
		-c "GRANT ALL PRIVILEGES ON DATABASE $$PG_DB TO $$PG_USER;" \
		2>&1 | grep -v "already exists" || true
	@echo "✓ Authentik database ready"

up-authentik:
	docker compose -f authentik/docker-compose.yml up -d

down-authentik:
	docker compose -f authentik/docker-compose.yml down

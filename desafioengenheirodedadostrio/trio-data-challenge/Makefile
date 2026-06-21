# =============================================================================
#  Trio Data Challenge — atalhos de operação
#  Rode a partir deste diretório (desafioengenheirodedadostrio/trio-data-challenge).
#  `make help` lista todos os alvos.
# =============================================================================
COMPOSE := docker compose

.DEFAULT_GOAL := help
.PHONY: help up down down-clean ps logs smoke lint psql-ts psql-legado ch reset

help: ## Lista os alvos disponíveis
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

up: ## Sobe o ambiente e aguarda todos os serviços ficarem healthy
	$(COMPOSE) up -d --wait

down: ## Derruba os containers (mantém os volumes/dados)
	$(COMPOSE) down

down-clean: ## Derruba e APAGA os volumes (re-roda os scripts de init/)
	$(COMPOSE) down -v

ps: ## Mostra o status/health dos serviços
	$(COMPOSE) ps

logs: ## Segue os logs de todos os serviços (Ctrl-C para sair)
	$(COMPOSE) logs -f

smoke: ## Roda o smoke test (valida os 4 serviços)
	./scripts/smoke-test.sh

lint: ## Valida o compose e roda linters disponíveis localmente
	$(COMPOSE) config -q && echo "compose: OK"
	@command -v shellcheck >/dev/null 2>&1 && shellcheck scripts/*.sh || echo "shellcheck ausente (rodará no CI)"
	@command -v yamllint  >/dev/null 2>&1 && yamllint docker-compose.yml || echo "yamllint ausente (rodará no CI)"

psql-ts: ## Abre psql no TimescaleDB (trio_transactions)
	$(COMPOSE) exec timescaledb psql -U $${POSTGRES_USER:-trio} -d trio_transactions

psql-legado: ## Abre psql no PostgreSQL legado (trio_legado)
	$(COMPOSE) exec postgres-legado psql -U $${POSTGRES_USER:-trio} -d trio_legado

ch: ## Abre o clickhouse-client (trio_analytics)
	$(COMPOSE) exec clickhouse clickhouse-client --user $${CLICKHOUSE_USER:-trio} --password $${CLICKHOUSE_PASSWORD:-trio2024} -d trio_analytics

reset: down-clean up smoke ## Recria tudo do zero e valida (down -v -> up --wait -> smoke)

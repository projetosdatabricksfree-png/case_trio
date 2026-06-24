# =============================================================================
#  Trio Data Challenge — atalhos de operação
#  Rode a partir deste diretório (desafioengenheirodedadostrio/trio-data-challenge).
#  `make help` lista todos os alvos.
# =============================================================================
COMPOSE := docker compose

.DEFAULT_GOAL := help
.PHONY: help up down down-clean ps logs smoke lint psql-ts psql-legado ch reset \
        migrate seed seed-smoke index analyze sanity \
        caggs policies index-s2 queries \
        migrate-legado seed-legado index-legado analyze-legado queries-legado \
        migrate-ch seed-ch seed-ch-smoke optimize-ch queries-ch \
        migrate-pipeline pipeline-once pipeline-refs pipeline-mutation-demo \
        backup recovery-demo runbook-storage-check incident-demo

# psql não-interativo no TimescaleDB (lê SQL do stdin).
PSQL_TS := $(COMPOSE) exec -T timescaledb psql -v ON_ERROR_STOP=1 -U $${POSTGRES_USER:-trio} -d trio_transactions

# psql não-interativo no PostgreSQL legado (lê SQL do stdin).
PSQL_LEGADO := $(COMPOSE) exec -T postgres-legado psql -v ON_ERROR_STOP=1 -U $${POSTGRES_USER:-trio} -d trio_legado

# clickhouse-client não-interativo (lê SQL do stdin; multiquery p/ arquivos com vários statements).
CH_Q := $(COMPOSE) exec -T clickhouse clickhouse-client --user $${CLICKHOUSE_USER:-trio} --password $${CLICKHOUSE_PASSWORD:-trio2024} -d trio_analytics --multiquery

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

smoke: ## Roda o smoke test (valida os 6 serviços)
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

# ----------------------------------------------------------------------------
#  Sprint 01 — schema + seed do TimescaleDB
# ----------------------------------------------------------------------------
migrate: ## Aplica o schema (DDL idempotente 00..05) no TimescaleDB
	@for f in desafio-1/schemas/0[0-5]_*.sql; do \
		printf '→ %s\n' "$$f"; \
		$(PSQL_TS) < "$$f" || exit 1; \
	done
	@echo "migrate: OK"

seed: ## Gera e carrega o seed completo (10M+). Ex.: SEED_TX=10000000 make seed
	$(COMPOSE) --profile tools run --rm seeder

seed-smoke: ## Seed rápido (~20k) para validação local/CI
	SEED_TX=20000 SEED_ACCOUNTS=2000 $(COMPOSE) --profile tools run --rm seeder

index: ## Cria os índices secundários de transactions (rodar PÓS-seed)
	$(PSQL_TS) < desafio-1/schemas/06_indexes.sql
	@echo "index: OK"

analyze: ## Atualiza estatísticas do planner (ANALYZE)
	$(PSQL_TS) -c "ANALYZE;"

sanity: ## Roda as queries de sanidade do seed
	@for f in desafio-1/queries/sanity/*.sql; do \
		printf '\n=== %s ===\n' "$$f"; \
		$(PSQL_TS) < "$$f"; \
	done

# ----------------------------------------------------------------------------
#  Sprint 02 — continuous aggregates, políticas e queries
# ----------------------------------------------------------------------------
caggs: ## Cria e materializa os 2 CAggs + refresh policies (Sprint 02)
	@for f in desafio-1/queries/caggs/0[1-4]_*.sql; do \
		printf '→ %s\n' "$$f"; \
		$(PSQL_TS) < "$$f" || exit 1; \
	done
	@echo "caggs: OK"

policies: ## Aplica compressão (7d) e retenção (raw 90d pausada + CAggs 2a)
	$(PSQL_TS) < desafio-1/queries/policies/compression.sql
	$(PSQL_TS) < desafio-1/queries/policies/retention.sql
	@echo "policies: OK"

index-s2: ## Cria os índices das queries Q2/Q4 (Sprint 02, rodar PÓS-seed)
	$(PSQL_TS) < desafio-1/schemas/07_indexes_sprint02.sql
	@echo "index-s2: OK"

queries: ## Roda Q1–Q4 + percentis exatos + gapfill (Sprint 02)
	@for f in desafio-1/queries/Q1.sql desafio-1/queries/Q2.sql \
	          desafio-1/queries/Q3.sql desafio-1/queries/Q4.sql \
	          desafio-1/queries/settlement_percentiles.sql \
	          desafio-1/queries/timeseries_gapfill_48h.sql; do \
		printf '\n=== %s ===\n' "$$f"; \
		$(PSQL_TS) < "$$f"; \
	done

# ----------------------------------------------------------------------------
#  Sprint 03 — PostgreSQL legado: schema, seed e queries
# ----------------------------------------------------------------------------
migrate-legado: ## Aplica o schema do legado (DDL idempotente 00..05) no postgres-legado
	@for f in desafio-1/schemas/legacy/0[0-5]_*.sql; do \
		printf '→ %s\n' "$$f"; \
		$(PSQL_LEGADO) < "$$f" || exit 1; \
	done
	@echo "migrate-legado: OK"

seed-legado: ## Popula o legado (users/accounts/configs/partners/limits). Ex.: SEED_USERS=30000
	$(COMPOSE) --profile tools run --rm seeder-legado

index-legado: ## Cria os índices de apoio do legado (rodar PÓS-seed)
	$(PSQL_LEGADO) < desafio-1/schemas/legacy/06_indexes_legacy.sql
	@echo "index-legado: OK"

analyze-legado: ## Atualiza estatísticas do planner no legado (ANALYZE)
	$(PSQL_LEGADO) -c "ANALYZE;"

queries-legado: ## Roda as queries do legado (relatório de contas + lookup de config)
	@for f in desafio-1/queries/legacy/*.sql; do \
		printf '\n=== %s ===\n' "$$f"; \
		$(PSQL_LEGADO) < "$$f"; \
	done

# ----------------------------------------------------------------------------
#  Sprint 04 — ClickHouse: schema (tabela + MVs + dictionary), carga e queries
# ----------------------------------------------------------------------------
migrate-ch: ## Aplica o schema do ClickHouse (tabela + 2 MVs + dictionary). Requer seed-legado p/ o dictionary
	@for f in desafio-1/schemas/clickhouse/0[0-3]_*.sql; do \
		printf '→ %s\n' "$$f"; \
		$(CH_Q) < "$$f" || exit 1; \
	done
	@printf '→ %s (senha injetada do .env via sed)\n' "desafio-1/schemas/clickhouse/04_dict_institutions.sql"
	@sed "s/__PG_PASSWORD__/$${POSTGRES_PASSWORD:-trio2024}/" \
		desafio-1/schemas/clickhouse/04_dict_institutions.sql | $(CH_Q) || exit 1
	@echo "migrate-ch: OK"

seed-ch: ## Carga do ClickHouse (CH_SEED_TX default 5M; suba p/ o headline sub-segundo)
	$(COMPOSE) --profile tools run --rm seeder-clickhouse

seed-ch-smoke: ## Carga pequena do ClickHouse (~200k) p/ validação local/CI
	CH_SEED_TX=200000 CH_SEED_BATCH=200000 $(COMPOSE) --profile tools run --rm seeder-clickhouse

optimize-ch: ## Força o merge (OPTIMIZE FINAL) p/ validar o dedup do ReplacingMergeTree
	$(CH_Q) -q "OPTIMIZE TABLE trio_analytics.transactions FINAL"
	@echo "optimize-ch: OK"

queries-ch: ## Roda as queries do ClickHouse (flagship sub-segundo, dictGet, MVs, dedup)
	@for f in desafio-1/queries/clickhouse/*.sql; do \
		printf '\n=== %s ===\n' "$$f"; \
		$(CH_Q) < "$$f"; \
	done

# ----------------------------------------------------------------------------
#  Sprint 05 — Pipelines: controle (CH) + leitura incremental (TS), sync e demos
# ----------------------------------------------------------------------------
migrate-pipeline: ## Cria as tabelas de controle do pipeline (CH) + índice de leitura (TS)
	@for f in desafio-2/pipeline/schema/0[0-3]_*.sql; do \
		printf '→ %s\n' "$$f"; \
		$(CH_Q) < "$$f" || exit 1; \
	done
	@printf '→ %s (TimescaleDB)\n' "desafio-2/pipeline/schema/10_ts_pipeline_index.sql"
	@$(PSQL_TS) < desafio-2/pipeline/schema/10_ts_pipeline_index.sql || exit 1
	@echo "migrate-pipeline: OK"

pipeline-once: ## Roda o pipeline principal uma vez (drena TS -> CH; idempotente)
	$(COMPOSE) run --rm --no-deps -T pipeline python sync_ts_to_ch.py --once

pipeline-refs: ## Full-refresh PostgreSQL legado -> CH (ref_institutions) + reload do dict
	$(COMPOSE) --profile tools run --rm pipeline-refs

pipeline-mutation-demo: ## Demonstra mutação pending -> settled refletida no CH (FINAL)
	./scripts/pipeline-mutation-demo.sh

# ----------------------------------------------------------------------------
#  Sprint 06 — Operação & Observabilidade: backup, recovery e runbook
# ----------------------------------------------------------------------------
backup: ## Backup dos 3 bancos (artefatos em desafio-3/backup/artifacts/)
	bash desafio-3/backup/run_backups.sh

recovery-demo: ## Demo de recovery do TimescaleDB (perda -> restore -> validação)
	bash desafio-3/backup/recovery-demo.sh

runbook-storage-check: ## Validação READ-ONLY do runbook de storage (não altera nada)
	$(PSQL_TS) < desafio-3/runbook-storage-check.sql
	@echo "runbook-storage-check: OK"

# ----------------------------------------------------------------------------
#  Sprint 07 — Incidente & Entrega: demo reproduzível do SEV-1 (volume zero)
# ----------------------------------------------------------------------------
incident-demo: ## Reproduz o incidente SEV-1 (pipeline cortado -> CH stale -> resolve -> CH==TS)
	bash scripts/incident-demo.sh

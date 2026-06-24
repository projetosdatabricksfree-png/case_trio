# Trio Data Challenge — Engenheiro de Dados Sênior

[![CI](https://github.com/projetosdatabricksfree-png/case_trio/actions/workflows/ci.yml/badge.svg)](https://github.com/projetosdatabricksfree-png/case_trio/actions/workflows/ci.yml)

Réplica autocontida da plataforma de dados da Trio: **3 bancos + observabilidade**, tudo via
`docker compose`. Este diretório é o **entregável** — todos os comandos abaixo rodam a partir daqui.

> Planejamento (PRD, ROADMAP, sprints) vive na raiz do monorepo, um nível acima.

## Pré-requisitos

- **Docker Engine 24+** e **Docker Compose v2** (`docker compose`, não o antigo `docker-compose`).
- Portas livres no host: `5432`, `5433`, `8123`, `9000`, `3000`, `8000`.
- (Opcional) `make` para os atalhos.

## Quick Start

```bash
cp .env.example .env
docker compose up -d --wait      # sobe e espera todos ficarem healthy
./scripts/smoke-test.sh          # valida os 6 serviços

# Equivalente com make:
make up && make smoke
```

`docker compose ps` deve mostrar os 6 serviços `healthy`.

## Serviços

Versões conforme o ambiente fornecido pelo escopo (Desafio Técnico §2.2). A escolha de usar
`latest` no ClickHouse e a estratégia de digest estão documentadas em
[`docs/adr/ADR-0001-image-versioning.md`](docs/adr/ADR-0001-image-versioning.md).

| Serviço | Imagem | Porta | Banco | Descrição |
|---|---|---|---|---|
| TimescaleDB | `timescale/timescaledb:latest-pg16` | `5432` | `trio_transactions` | Transacional principal |
| PostgreSQL Legado | `postgres:16-bookworm` | `5433` | `trio_legado` | Legado (candidato a Aurora/RDS) |
| ClickHouse | `clickhouse/clickhouse-server:latest` | `8123` (HTTP) / `9000` (nativo) | `trio_analytics` | Motor analítico |
| Grafana | `grafana/grafana:latest` | `3000` | — | Dashboards (admin/admin) |
| API | FastAPI + Uvicorn (`./desafio-1/api`) | `8000` | — | ClickHouse servindo aplicação (RF-3.5) |
| Pipeline | Python (`./desafio-2/pipeline`) | — | — | Micro-batch idempotente TimescaleDB → ClickHouse (RF-4.x) |

## Conexões

```bash
# TimescaleDB
docker compose exec timescaledb psql -U trio -d trio_transactions
# PostgreSQL Legado
docker compose exec postgres-legado psql -U trio -d trio_legado
# ClickHouse (CLI)
docker compose exec clickhouse clickhouse-client --user trio --password trio2024 -d trio_analytics
# ClickHouse (HTTP)
curl "http://localhost:8123/?user=trio&password=trio2024&database=trio_analytics" --data "SELECT 1"
# Grafana — http://localhost:3000 (admin/admin), datasources já provisionados
# API — http://localhost:8000/docs (Swagger); ClickHouse em tempo real, em JSON
curl -fsS "http://localhost:8000/transactions/volume/realtime?window_minutes=60"
curl -fsS "http://localhost:8000/institutions/00000000/health?window_minutes=1440"
```

Atalhos: `make psql-ts`, `make psql-legado`, `make ch`.

## Comandos (make)

| Alvo | O que faz |
|---|---|
| `make up` | Sobe e aguarda todos healthy (`up -d --wait`) |
| `make smoke` | Roda o smoke test dos 6 serviços |
| `make ps` / `make logs` | Status/health · logs em tempo real |
| `make down` | Derruba containers (**mantém** dados) |
| `make down-clean` | Derruba e **apaga** volumes (re-roda `init/`) |
| `make reset` | `down-clean` → `up` → `smoke` (recria do zero e valida) |
| `make lint` | Valida o compose + linters locais |
| `make migrate` · `seed` · `index` · `queries` | TimescaleDB (Sprint 01–02): schema → seed 10M → índices → Q1–Q4 |
| `make migrate-legado` · `seed-legado` · `index-legado` · `queries-legado` | Legado (Sprint 03): schema → seed → índices → queries |
| `make migrate-ch` · `seed-ch` · `optimize-ch` · `queries-ch` | ClickHouse (Sprint 04): tabela+MVs+dictionary → carga → OPTIMIZE FINAL → flagship/dictGet |
| `make migrate-pipeline` · `pipeline-once` · `pipeline-refs` · `pipeline-mutation-demo` | Pipelines (Sprint 05): tabelas de controle → sync TS→CH idempotente → refresh de referência → demo de mutação |
| `make backup` · `recovery-demo` · `runbook-storage-check` | Operação (Sprint 06): backup dos 3 bancos → demo de recovery validada → validação read-only do runbook de storage |
| `make incident-demo` | Incidente (Sprint 07): reproduz o SEV-1 de volume zero no ClickHouse → resolução → CH converge com o TS |

## Como demonstrar cada parte

Sequência completa do zero (smoke seed ~20k; troque por `make seed`/`seed-ch` para volume cheio). É a
mesma ordem que o CI executa.

```bash
make reset                                   # down -v -> up -> smoke (ambiente limpo, 6 serviços)

# Desafio 1 — TimescaleDB: modelagem, CAggs, políticas, queries Q1–Q4 (EXPLAIN antes/depois)
make migrate seed-smoke index sanity
make index-s2 caggs policies queries

# Desafio 1 — Legado + migração (RDS/Aurora) e ClickHouse + API
make migrate-legado seed-legado index-legado queries-legado
make migrate-ch seed-ch-smoke queries-ch optimize-ch
curl -fsS "http://localhost:8000/transactions/volume/realtime?window_minutes=1440" | jq

# Desafio 2 — Pipeline TS → CH: idempotência (rodar 2x não duplica), mutação e DLQ
make migrate-pipeline pipeline-once pipeline-refs pipeline-mutation-demo

# Desafio 3 — Operação: backup/recovery, runbook, dashboards/alertas e incidente SEV-1
make backup recovery-demo runbook-storage-check
make incident-demo                           # volume zero no CH -> resolução -> CH == TS
# Grafana http://localhost:3000 (admin/admin): pasta 'Trio' com 4 dashboards + alerta PoC
```

Detalhe de cada resultado (EXPLAIN, RTO/RPO, hipóteses do incidente) nos REPORTs e docs por desafio;
mapa em [`docs/validation-checklist.md`](docs/validation-checklist.md) e no
[índice de entregáveis](../../README.md#índice-de-entregáveis) da raiz.

## Estrutura

```
trio-data-challenge/
├── docker-compose.yml          # 6 serviços, healthchecks, tuning, log rotation
├── .env.example                # credenciais de dev (copie para .env)
├── Makefile                    # atalhos de operação
├── scripts/smoke-test.sh       # validação dos 6 serviços (usada também no CI)
├── init/                       # SQL de bootstrap (só roda em volume vazio)
│   ├── timescaledb/  · postgres-legado/  · clickhouse/
├── desafio-1/                  # Performance e tuning (schemas[/legacy,/clickhouse], seed, queries[/legacy,/clickhouse], api)
├── desafio-2/                  # Pipelines e arquitetura (pipeline, diagrams, ADR)
├── desafio-3/                  # Operação e observabilidade
│   ├── backup/                 # backup dos 3 bancos + recovery-demo (✅)
│   ├── runbook.md · alerts.md  # runbook de storage + alertas críticos (✅)
│   ├── incident-response.md    # resposta ao SEV-1 (make incident-demo) (✅)
│   └── grafana/provisioning/   # datasources + 4 dashboards + alerta PoC (✅)
└── docs/                       # ADRs + validation-checklist.md
```

## Persistência: `down` vs `down -v`

- `docker compose down` — para os containers, **preserva** os volumes (os dados continuam).
- `docker compose down -v` — **apaga** os volumes. Use para re-testar do zero: os scripts de
  `init/` só executam na **primeira** criação de cada container (volume vazio).

## Troubleshooting

| Sintoma | Causa provável | Solução |
|---|---|---|
| ClickHouse não sobe / `nofile` | limite de file descriptors baixo no host | já tratado via `ulimits.nofile` no compose |
| Scripts de `init/` não rodaram | volume não estava vazio | `docker compose down -v` e suba de novo |
| `port is already allocated` | porta ocupada no host | libere a porta ou ajuste o mapeamento no compose |
| Grafana fica `starting` | ainda dentro do `start_period` do healthcheck | aguarde ~20s; veja `docker compose logs grafana` |
| Senha inválida nos bancos | `.env` divergente dos volumes já criados | `down -v` para recriar com as credenciais atuais |

## Entrega — registrar versão/digest

Como o escopo usa tags móveis, capture o digest avaliado (ver ADR-0001):

```bash
docker compose pull && docker compose images
```

## CI/CD

A cada push/PR para `main`, o GitHub Actions roda **lint** (compose config, yamllint,
shellcheck, gitleaks) e um job de **integração** que sobe o ambiente com `--wait` e executa o
smoke test. Detalhes em [`../../.github/workflows/`](../../.github/workflows/). Recomenda-se
proteger `main` exigindo o check de integração como obrigatório.

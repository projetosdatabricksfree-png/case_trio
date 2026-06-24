# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

# Trio Data Challenge

Réplica autocontida da plataforma de dados da Trio (instituição de pagamentos). Desafio técnico de Engenheiro de Dados Sênior: **3 bancos + pipeline + observabilidade**, tudo via docker-compose. Critério-mestre: tudo precisa ser **defensável ao vivo** (terminal, código, dashboards).

## Layout do Repositório (ler primeiro)

O repositório tem **dois níveis** — não confunda:

- **Raiz (`case_trio/`)** — planejamento e docs: `PRD.md`, `ROADMAP.md`, `sprints/`, este `CLAUDE.md`.
- **Projeto deployável: `desafioengenheirodedadostrio/trio-data-challenge/`** — é onde moram `docker-compose.yml`, `.env.example` e `init/`. **Todo comando `docker compose` roda a partir daqui.**

## Estado Atual

**Projeto completo (Sprints 00–07), entregue e mergeado em `main`** — os três desafios cobertos de ponta a ponta e validados no CI a cada push. No compose: os 4 serviços de dados + pipeline + API. Já existem: schema/seed/queries dos 3 bancos, pipeline idempotente TimescaleDB → ClickHouse, dashboards/alertas no Grafana (`desafio-3/grafana/provisioning/`), backup/recovery, runbook de storage e resposta ao incidente SEV-1. Os scripts `init/{timescaledb,postgres-legado,clickhouse}/00_init.sql` permanecem como **bootstrap mínimo** (extensões / `CREATE DATABASE`); o schema versionado de cada banco vive em `desafio-1/schemas/` e roda via `make` (ver `ROADMAP.md` e o índice de entregáveis no README raiz).

> Os scripts `init/` só executam na **primeira criação** do container (volume vazio). Para reaplicá-los após editar: `docker compose down -v` (apaga os dados) e suba de novo.

## Stack

- Transacional principal: **TimescaleDB** (`timescale/timescaledb:latest-pg16`, porta 5432, db `trio_transactions`)
- Legado: **PostgreSQL 16** (`postgres:16-bookworm`, porta 5433, db `trio_legado`)
- Analítico: **ClickHouse** (`clickhouse/clickhouse-server:latest`, porta 8123 HTTP / 9000 native, db `trio_analytics`)
- Dashboards: **Grafana** (`grafana/grafana:latest`, porta 3000, admin/admin; datasources dos 3 bancos pré-configurados)
- Pipeline: **Python 3.12** (psycopg, clickhouse-connect) — micro-batch idempotente
- API: **FastAPI + Uvicorn**

## Credenciais (dev — via `.env`)

- Postgres/Timescale: usuário `trio`, senha `trio2024`
- ClickHouse: usuário `trio`, senha `trio2024`
- Grafana: `admin` / `admin`

## Comandos

Rode tudo de dentro de `desafioengenheirodedadostrio/trio-data-challenge/`:

```bash
cp .env.example .env            # primeira vez
docker compose up -d            # subir ambiente
docker compose logs -f <serviço># logs (timescaledb | postgres-legado | clickhouse | grafana)
docker compose down -v          # derrubar e apagar volumes (re-roda init/)

# Conexões
docker compose exec timescaledb psql -U trio -d trio_transactions
docker compose exec postgres-legado psql -U trio -d trio_legado
docker compose exec clickhouse clickhouse-client --user trio --password trio2024 -d trio_analytics
```

## Convenções

- SQL: snake_case, keywords maiúsculas, um statement por arquivo de migration. Migrations entram em `init/<banco>/NN_descricao.sql` (rodam em ordem alfabética).
- Python: type hints, logging estruturado (JSON), sem credenciais hardcoded.
- Docs: MD sempre; cada query acompanhada de `EXPLAIN ANALYZE` antes/depois.
- Commits: conventional commits.
- Segredos: somente via `.env` (commitar apenas `.env.example`).

## Decisões Arquiteturais (estáveis)

- **Pipeline = micro-batch Python**, não Debezium/Kafka: demonstrável no compose; CDC fica como evolução AWS (ADR previsto na sprint 05).
- **ClickHouse engine = ReplacingMergeTree** para `transactions`: trata mutação de status via coluna `version`, sem UPDATE real.
- **Hypertable chunk = 1 dia**: padrão de consulta concentra em 30–90 dias; compressão/retenção granular.
- **Dictionaries no ClickHouse** para lookups (institution_code→name): evita JOIN custoso.
- **Seed via COPY/batch**, nunca INSERT linha a linha: 10M rows em < 15 min.
- **Versões = ambiente fornecido pelo escopo** (PDF §2.2 "Ambiente Fornecido"): TimescaleDB 2.x, PostgreSQL 16, **ClickHouse `latest`**, Grafana. O `docker-compose.yml` segue exatamente isso — `clickhouse/clickhouse-server:latest` é intencional, não um gap. Pinar imagens (tag/digest fixos) fica como recomendação para **produção AWS** (registrar em ADR/runbook), não para o ambiente do desafio.

## Workflow

- Modelo padrão: **Sonnet**. Opus só para decisões arquiteturais (ADR 5.6, análise de migração 3.4, runbook de storage 6.3, incidente 7.1).
- Implementar **uma story por vez**; `/compact` entre stories preservando: decisões de arquitetura, schemas criados, queries validadas.
- Referência cirúrgica: `@sprints/sprint-0X-nome.md` story específica, **nunca o repo inteiro**.
- **Plan Mode antes de implementar** qualquer story não-trivial.

## Mapa de Documentos

- `PRD.md` — requisitos completos (carregar só quando precisar do contexto de negócio)
- `ROADMAP.md` — 8 sprints (00–07), 42 stories, cronograma de 7 dias, dependências
- `sprints/sprint-00-foundation.md` — docker-compose, init, env
- `sprints/sprint-01-timescaledb-modeling.md` — schema, hypertable, seed
- `sprints/sprint-02-timescaledb-queries.md` — CAggs, políticas, Q1–Q4, LGPD
- `sprints/sprint-03-postgresql-legado.md` — schema legado, queries, migração
- `sprints/sprint-04-clickhouse.md` — engine, MVs, dictionary, query Grafana, API
- `sprints/sprint-05-pipelines-arquitetura.md` — sync, mutações, diagrama, ADR
- `sprints/sprint-06-ops-observabilidade.md` — backup, recovery, dashboards, alertas
- `sprints/sprint-07-incidente-entrega.md` — SEV-1, README, prep apresentação

## Lembretes de Entrega

- "Se não está documentado, não existe" — cada sprint gera seus artefatos de doc.
- Pragmatismo > perfeição: 70% muito bem feito > 100% superficial.
- Tudo deve ser **defensável ao vivo** na apresentação (terminal, código, dashboards).

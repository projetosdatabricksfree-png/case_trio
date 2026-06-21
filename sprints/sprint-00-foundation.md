# Sprint 00 — Foundation & Infraestrutura

> **Dia:** 1 (manhã) · **Peso:** Pré-requisito · **Stories:** 4
> **Objetivo:** Ambiente 100% autocontido que sobe com `docker compose up -d` sem erros, com os 4 serviços saudáveis e estrutura de repositório pronta.

---

## Contexto

Tudo depende desta sprint. Os critérios mínimos de aceitação começam aqui: *"`docker-compose up -d` sobe todo o ambiente sem erros"*. Não avance para a Sprint 01 antes dos health checks passarem.

**Depende de:** nada.
**Habilita:** todas as demais sprints.

---

## Definition of Done da Sprint

- [ ] `docker compose up -d` sobe TimescaleDB, PostgreSQL, ClickHouse e Grafana sem erro.
- [ ] `docker compose ps` mostra todos os serviços `healthy`.
- [ ] Estrutura de diretórios do repositório criada conforme §6 do desafio.
- [ ] `.env.example` presente; `.env` no `.gitignore`.
- [ ] README raiz com instruções de setup mínimas.
- [ ] Extensão TimescaleDB carregada e verificável (`SELECT extversion FROM pg_extension WHERE extname='timescaledb'`).

---

## Story 0.1 — Estrutura de repositório e versionamento

**Descrição:** Criar a árvore de diretórios e arquivos base do repositório conforme a estrutura sugerida no desafio.

**Tarefas:**
- Criar a árvore:
  ```
  trio-data-challenge/
  ├── README.md
  ├── docker-compose.yml
  ├── .env.example
  ├── .gitignore
  ├── init/
  │   ├── timescaledb/
  │   ├── postgres-legado/
  │   └── clickhouse/
  ├── desafio-1/                 # Performance e Tuning de Queries
  │   ├── schemas/
  │   ├── seed/
  │   ├── queries/
  │   ├── api/                   # FastAPI servindo ClickHouse (RF-3.5, Parte C)
  │   ├── migration-analysis.md
  │   └── REPORT.md
  ├── desafio-2/                 # Pipelines de Dados e Arquitetura
  │   ├── pipeline/
  │   ├── diagrams/
  │   └── ADR.md
  ├── desafio-3/                 # Operação, Resiliência e Observabilidade
  │   ├── backup/
  │   ├── grafana/
  │   │   └── provisioning/      # datasources + dashboards + alerting (montado pelo compose)
  │   ├── runbook.md
  │   └── incident-response.md
  └── docs/
  ```
- `.gitignore` cobrindo `.env`, `__pycache__/`, `*.pyc`, volumes locais, dumps de backup.
- `git init` + commit inicial.

**Critério de aceitação:** árvore criada; `.env` ignorado; primeiro commit feito.

**Artefatos:** estrutura de diretórios, `.gitignore`.

---

## Story 0.2 — docker-compose base com os 4 serviços

**Descrição:** Evoluir o `docker-compose.yml` base com os 4 serviços nas **versões do ambiente fornecido pelo escopo** (§2.2), volumes nomeados, rede dedicada, variáveis via `.env` e **health checks**.

**Tarefas:**
- Serviços nas versões do escopo (§2.2 "Ambiente Fornecido"):
  - `timescaledb`: `timescale/timescaledb:latest-pg16` (Timescale 2.x sobre PostgreSQL 16) — porta 5432.
  - `postgres-legado`: `postgres:16-bookworm` — porta 5433.
  - `clickhouse`: `clickhouse/clickhouse-server:latest` (o escopo especifica `latest`) — portas 8123/9000.
  - `grafana`: `grafana/grafana:latest` — porta 3000.
- Volumes nomeados para persistência de cada banco.
- Rede `trio-data-network` dedicada (bridge) para comunicação entre serviços por nome.
- Credenciais via `.env` (`POSTGRES_USER`/`POSTGRES_PASSWORD`, `CLICKHOUSE_USER`/`CLICKHOUSE_PASSWORD`). Os **nomes de DB** (`trio_transactions`, `trio_legado`, `trio_analytics`) e o **admin do Grafana** (`admin`/`admin`) ficam fixos no compose, não no `.env`.
- **Health checks** em cada serviço:
  - TimescaleDB/PostgreSQL: `pg_isready`.
  - ClickHouse: `wget --spider http://localhost:8123/ping` ou `clickhouse-client --query "SELECT 1"`.
  - Grafana: `wget --spider http://localhost:3000/api/health`.
- `depends_on` com `condition: service_healthy` onde fizer sentido (Grafana depende dos bancos).
- `restart: unless-stopped` em todos.

**Critério de aceitação:** `docker compose up -d` sobe tudo; `docker compose ps` mostra `healthy` em todos após o período de inicialização.

**Atenção:**
- ClickHouse exige `ulimits` (nofile) ajustado em alguns hosts — incluir no compose.
- Montar `init/clickhouse` em `/docker-entrypoint-initdb.d/` para scripts de schema.
- TimescaleDB monta `init/timescaledb` em `/docker-entrypoint-initdb.d/` (rodam em ordem alfabética — prefixar `01_`, `02_`).
- Grafana monta `desafio-3/grafana/provisioning` em `/etc/grafana/provisioning` (datasources já provisionados na foundation; dashboards/alertas do Desafio 3 entram aqui — ver §6 do desafio).

**Artefatos:** `docker-compose.yml`.

---

## Story 0.3 — Variáveis de ambiente e bootstrap de init

**Descrição:** Definir `.env.example` documentado e os scripts de init mínimos que garantem extensão, usuários e databases prontos no primeiro boot.

**Tarefas:**
- `.env.example` apenas com as credenciais (usuário/senha), valores-exemplo seguros:
  ```
  # TimescaleDB & PostgreSQL Legado
  POSTGRES_USER=trio
  POSTGRES_PASSWORD=trio2024
  # ClickHouse
  CLICKHOUSE_USER=trio
  CLICKHOUSE_PASSWORD=trio2024
  ```
  - Os **nomes de DB** (`POSTGRES_DB=trio_transactions` no Timescale, `trio_legado` no legado, `CLICKHOUSE_DB=trio_analytics`) e o **admin do Grafana** (`GF_SECURITY_ADMIN_USER`/`GF_SECURITY_ADMIN_PASSWORD=admin`) ficam fixos no `docker-compose.yml`, não no `.env`.
- `init/timescaledb/00_init.sql`: `CREATE EXTENSION IF NOT EXISTS timescaledb;`
- `init/clickhouse/00_init.sql`: garantir o database `trio_analytics` (idempotente).
- `init/postgres-legado/00_init.sql`: stub do legado (extensões/parâmetros conforme necessário).
- Garantir que os scripts de init são idempotentes (`IF NOT EXISTS`).

**Critério de aceitação:** após `up -d` limpo, extensão TimescaleDB ativa; databases `trio_transactions` / `trio_legado` / `trio_analytics` criados; conexão com as credenciais do `.env` funciona nos 3 bancos.

**Atenção:** scripts de init só rodam quando o volume está **vazio**. Para re-testar do zero: `docker compose down -v`.

**Artefatos:** `.env.example`, `init/timescaledb/00_init.sql`, `init/postgres-legado/00_init.sql`, `init/clickhouse/00_init.sql`.

---

## Story 0.4 — README raiz e validação do ambiente

**Descrição:** README com setup mínimo e um script/checklist de smoke test que prova o ambiente saudável.

**Tarefas:**
- README raiz com seções: pré-requisitos (Docker + Compose), setup (`cp .env.example .env`, `docker compose up -d`), portas expostas, como conectar a cada banco, troubleshooting comum.
- Smoke test (script bash ou seção no README) validando:
  - `SELECT extversion FROM pg_extension WHERE extname='timescaledb';` (TimescaleDB)
  - `SELECT version();` (PostgreSQL legado)
  - `SELECT version();` via `clickhouse-client` (ClickHouse)
  - `curl http://localhost:3000/api/health` (Grafana)
- Documentar `docker compose down` vs `down -v` (cuidado com perda de dados).

**Critério de aceitação:** seguindo só o README, um avaliador sobe o ambiente do zero e valida os 4 serviços.

**Artefatos:** `README.md` (raiz), smoke test.

---

## Riscos da Sprint

| Risco | Mitigação |
|---|---|
| ClickHouse falha por `nofile` baixo | Definir `ulimits.nofile` no compose |
| Scripts de init não rodam (volume não-vazio) | Documentar `down -v`; init é só primeiro boot |
| Grafana sobe antes dos bancos | `depends_on` com `service_healthy` |
| ClickHouse `latest` (exigido pelo escopo §2.2) muda comportamento | Registrar versão/digest usada na entrega + smoke test; pinagem fica como recomendação de produção AWS |

---

## Saída para a próxima sprint

Com o ambiente saudável, a Sprint 01 assume TimescaleDB pronto para receber schema transacional e seed. Faça `/compact` preservando: estrutura do compose, nomes de serviços/portas, credenciais via `.env`.

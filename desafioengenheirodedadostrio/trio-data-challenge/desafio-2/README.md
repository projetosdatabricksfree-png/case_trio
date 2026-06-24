# Desafio 2 — Pipelines de Dados e Arquitetura

Pipeline de sincronização **TimescaleDB → ClickHouse** (micro-batch idempotente),
pipeline de **referência PostgreSQL → ClickHouse**, [diagramas de arquitetura](diagrams/architecture.md)
e o [ADR](ADR.md) que justifica as escolhas (micro-batch vs CDC, plano de escala 10x).

> Cobre RF-4.1 a RF-4.6. Decisões: micro-batch idempotente (não CDC) — 100% demonstrável
> no compose; o dictionary da Sprint 04 segue intacto (lendo o PostgreSQL direto).

## Componentes

| Artefato | Papel |
|---|---|
| `pipeline/sync_ts_to_ch.py` | Pipeline principal: TimescaleDB → ClickHouse, micro-batch idempotente, mutações, DLQ |
| `pipeline/sync_pg_refs.py` | Pipeline de referência: PostgreSQL legado → `ref_institutions` + `SYSTEM RELOAD DICTIONARY` |
| `pipeline/pipeline_config.py` · `pipeline_logging.py` | Config por env + logging JSON (mesmo padrão do seeder) |
| `pipeline/schema/*.sql` | Tabelas de controle no ClickHouse (`pipeline_watermark`, `pipeline_runs`, `pipeline_dlq`, `ref_institutions`) + índice no TimescaleDB |
| serviço `pipeline` (compose) | Loop contínuo (poll), healthcheck por heartbeat — sobe no `docker compose up` |
| serviço `pipeline-refs` (profile `tools`) | One-shot do pipeline de referência |

## Como funciona (resumo)

A origem é uma **hypertable comprimida** (Sprint 02). O pipeline lê em **duas passadas**:

- **INSERT pass** — janelas de tempo half-open sobre `created_at` (coluna de partição/orderby
  da compressão) → **poda de chunk**, sem Sort global; cobre backfill e linhas novas.
- **MUTATE pass** — keyset `(settled_at, id)` → capta `pending → settled` (a mutação preenche
  `settled_at`), watermark iniciado em `max(settled_at)` para pegar só mutações futuras.

**Idempotência** = watermark (não relê o inalterado) + `ReplacingMergeTree(version)` (colapsa o
reinserido); o `id`/`external_id` da origem são carregados explicitamente para o dedup funcionar.
**Observabilidade** = logs JSON + tabela `pipeline_runs` (consumida pelo dashboard da Sprint 06).
**Resiliência** = retry com backoff exponencial; dado poison vai para `pipeline_dlq`.

Detalhes e trade-offs (consistência `FINAL`/`argMax`, double-count das MVs, watermark derivado vs.
`updated_at`): ver [ADR.md](ADR.md).

## Como rodar

```bash
# (a partir de desafioengenheirodedadostrio/trio-data-challenge)
make up                          # sobe 6 serviços (inclui o pipeline contínuo)
make migrate seed-smoke index    # origem TimescaleDB com dados
make migrate-ch                  # destino ClickHouse (Sprint 04)
make migrate-pipeline            # tabelas de controle (CH) + índice de mutação (TS)

make pipeline-once               # drena TS -> CH (insert + mutate). Idempotente:
make pipeline-once               #   rodar de novo NÃO altera a contagem (FINAL)
make pipeline-mutation-demo      # pending -> settled refletido no CH via FINAL/argMax
make pipeline-refs               # PostgreSQL -> CH (ref_institutions) + reload do dictionary

docker compose logs -f pipeline  # loop contínuo: lag/throughput em JSON
```

Inspeção das tabelas de controle:

```sql
-- no ClickHouse (make ch)
SELECT * FROM pipeline_runs ORDER BY started_at DESC LIMIT 5;        -- métricas por execução
SELECT pipeline, max(last_value) FROM pipeline_watermark GROUP BY pipeline;  -- progresso
SELECT * FROM pipeline_dlq ORDER BY failed_at DESC LIMIT 5;          -- dead-letter
SELECT * FROM ref_institutions ORDER BY institution_code LIMIT 5;    -- referência sincronizada
```

## Validação (evidências)

Medições locais (TimescaleDB com seed de 10M; ClickHouse já com a carga da Sprint 04). Em CI a
mesma sequência roda no smoke (~20k) com asserções (ver `.github/workflows/ci.yml`).

| Prova | Resultado medido |
|---|---|
| **Throughput (backfill)** | 10.000.000 linhas TimescaleDB → ClickHouse em **283 s (~35k linhas/s)**, em janelas de `created_at` (poda de chunk na hypertable comprimida) |
| **Idempotência** | 2ª execução (`--once`) lê **0 linhas**, `lag_seconds=0`; `count() FINAL` **inalterado** (60M = 50M da Sprint 04 + 10M sincronizados, sem duplicar) |
| **Mutação `pending → settled`** | refletida no ClickHouse via `FINAL`/`argMax(version)`, **1 linha** para a tx (versão maior vence, sem duplicar) |
| **Pipeline de referência** | `ref_institutions` = **30 linhas**; `SYSTEM RELOAD DICTIONARY` ok; `dictGet(...,'00000000')` = `Banco do Brasil S.A.` |
| **DLQ (fault-injection)** | `--demo-dlq` roteia **1 registro** inválido (`amount inválido: -1`, `retries=3`) para `pipeline_dlq`, sem tocar dado real |
| **Observabilidade** | `pipeline_runs` registra cada execução (`rows_read/written`, `lag_seconds`, `duration_ms`, `status`) → dashboard da Sprint 06 |

> O lag é **relativo à origem** (`max(created_at) − watermark`), não ao relógio: o seed é estático,
> então freshness vs. `now()` não teria sentido; lag = 0 quando o pipeline alcança a origem.
> O sweep de mutação em chunk comprimido custa um `ColumnarScan` de `settled_at` (segundos em 10M;
> instantâneo no smoke do CI) — trade-off documentado no [ADR](ADR.md); produção (CDC) o dispensa.


> Reprodução: `make migrate-pipeline && make pipeline-once` (2×) `&& make pipeline-mutation-demo
> && make pipeline-refs`.

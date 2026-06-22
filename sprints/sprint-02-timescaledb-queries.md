# Sprint 02 — TimescaleDB: Agregados, Políticas & Queries

> **Dias:** 2–3 · **Peso:** Profundidade Técnica (40%) · **Stories:** 6
> **Cobre:** RF-1.4 a RF-1.8 · **Desafio 1 / Parte A** (tarefas 4–9)
> **Objetivo:** Continuous aggregates funcionais, políticas de retenção/compressão ativas, queries Q1–Q4 otimizadas com `EXPLAIN ANALYZE` comparativo, série temporal com gapfill, e procedimento LGPD para chunks comprimidos.

---

## Contexto

Esta é a sprint de **maior densidade técnica** do desafio — é aqui que a nota de 40% se decide. Cada query precisa de `EXPLAIN ANALYZE` **antes e depois** da otimização, com análise real do plano (não copiar o output cru). O avaliador disse explicitamente: *"queremos ver seu raciocínio, não output de LLM"*.

**Depende de:** Sprint 01 (`transactions` populada e `ANALYZE`-da).
**Habilita:** Sprint 05 (CAggs podem ser sincronizados), Sprint 06 (dashboards leem CAggs).

---

## Definition of Done da Sprint

- [x] 2 continuous aggregates criados **com refresh policy** e materializando dados.
- [x] Políticas de retenção (raw 90d, CAggs 2 anos) e compressão (chunks 7+ dias) ativas.
- [x] Q1–Q4 escritas, otimizadas, com `EXPLAIN ANALYZE` antes/depois documentado.
- [x] Índices criados justificados; impacto do particionamento (chunk exclusion) demonstrado.
- [x] Query com `time_bucket_gapfill` + `locf`/`interpolate` para 48h.
- [x] Procedimento de sanitização LGPD de chunks comprimidos documentado e (idealmente) demonstrado.
- [x] `REPORT.md` consolidado com todos os planos e análises.

---

## Story 2.1 — Continuous aggregates (volume/valor + latência P95/P99)

**Descrição:** Criar os dois continuous aggregates exigidos, com políticas de refresh automático.

**Tarefas:**
- **CAgg A** — volume e valor total por tipo de transação, por hora:
  ```sql
  CREATE MATERIALIZED VIEW cagg_volume_by_type_hourly
  WITH (timescaledb.continuous) AS
  SELECT time_bucket('1 hour', created_at) AS bucket,
         type,
         count(*) AS tx_count,
         sum(amount) AS total_amount
  FROM transactions
  GROUP BY bucket, type;
  ```
- **CAgg B** — P95 e P99 de latência de liquidação (`settled_at - created_at`) por instituição, por dia:
  - Usar `percentile_cont` ou `approx_percentile` (TimescaleDB Toolkit) — decidir e justificar (toolkit é mais rápido em escala; `percentile_cont` é exato). Filtrar `status = 'settled'` (latência só faz sentido para liquidadas).
- **Refresh policy obrigatória** em ambos:
  ```sql
  SELECT add_continuous_aggregate_policy('cagg_volume_by_type_hourly',
    start_offset => INTERVAL '3 days',
    end_offset   => INTERVAL '1 hour',
    schedule_interval => INTERVAL '1 hour');
  ```

**Critério de aceitação:** ambos os CAggs retornam dados; `timescaledb_information.continuous_aggregates` lista os dois; jobs de refresh aparecem em `timescaledb_information.jobs`.

**Atenção:** sem `add_continuous_aggregate_policy`, o CAgg **não atualiza sozinho** — falha silenciosa clássica. Validar com `CALL refresh_continuous_aggregate(...)` manual e depois confirmar o job automático.

**Artefatos:** `desafio-1/queries/caggs/cagg_volume.sql`, `cagg_latency.sql`.

---

## Story 2.2 — Políticas de retenção e compressão

**Descrição:** Configurar compressão automática e retenção conforme os SLAs do desafio.

**Tarefas:**
- **Compressão** de chunks com 7+ dias:
  ```sql
  ALTER TABLE transactions SET (
    timescaledb.compress,
    timescaledb.compress_orderby = 'created_at DESC',
    timescaledb.compress_segmentby = 'type, source_institution');
  SELECT add_compression_policy('transactions', INTERVAL '7 days');
  ```
  - Justificar `segmentby` (colunas usadas em filtros/agrupamentos → melhor razão de compressão e queries em dados comprimidos) e `orderby`.
- **Retenção raw** 90 dias na hypertable: `SELECT add_retention_policy('transactions', INTERVAL '90 days');`
- **Retenção CAggs** 2 anos: `add_retention_policy` no(s) CAgg(s) com `INTERVAL '2 years'`.
- Validar que retenção da hypertable **não apaga** o que já está agregado no CAgg (CAgg tem retenção própria, maior).

**Critério de aceitação:** políticas listadas em `timescaledb_information.jobs`; ao menos um chunk antigo efetivamente comprimido (`SELECT * FROM chunk_compression_stats('transactions')` mostra ganho).

**Decisão a registrar:** ordem importa — retenção raw de 90 dias só é segura porque os CAggs já materializaram o histórico necessário. Documentar essa dependência.

**Artefatos:** `desafio-1/queries/policies/compression.sql`, `retention.sql`, seção no REPORT.

---

## Story 2.3 — Queries Q1 e Q2 com otimização

**Descrição:** Implementar e otimizar Q1 (volume/valor por tipo e status, por mês, 6 meses) e Q2 (divergências de reconciliação, 30 dias, com contas).

**Tarefas:**
- **Q1** — volume e valor total por tipo e status, agrupado por mês, últimos 6 meses:
  - Versão ingênua → `EXPLAIN ANALYZE`.
  - Otimizar: `time_bucket('1 month', ...)`, considerar servir do **CAgg** quando aplicável, índice em `(created_at, type, status)` se necessário.
  - `EXPLAIN ANALYZE` depois; comparar (chunk exclusion, redução de rows scanned).
- **Q2** — transações com divergência (`amount_expected` vs `amount_received` > R$0,01) nos últimos 30 dias, com dados das contas de origem e destino:
  - JOIN `reconciliation_events` × `transactions` × `accounts` (origem e destino).
  - `EXPLAIN ANALYZE` antes; otimizar índices em `reconciliation_events(reconciled_at)`, `transactions(external_id)`, join keys; depois comparar.
  - Avaliar índice parcial em divergências (`WHERE difference > 0.01`) — justificar.

**Critério de aceitação:** ambas executam corretamente; `EXPLAIN ANALYZE` antes/depois documentado com análise do que mudou no plano.

**Artefatos:** `desafio-1/queries/Q1.sql`, `Q2.sql` (cada uma com bloco de EXPLAIN comentado).

---

## Story 2.4 — Queries Q3 e Q4 com otimização

**Descrição:** Implementar e otimizar Q3 (top 20 instituições, 90 dias) e Q4 (detecção de duplicatas em janela de 5 min).

**Tarefas:**
- **Q3** — top 20 instituições por volume transacionado nos últimos 90 dias, com média de tempo de liquidação e taxa de falha:
  - Agregação por `source_institution`; `avg(settled_at - created_at)` filtrando settled; `count(*) FILTER (WHERE status='failed') / count(*)` para taxa de falha.
  - `EXPLAIN ANALYZE` antes/depois; índice/CAgg apropriado.
- **Q4** — detecção de possíveis duplicatas (mesmo valor, mesma origem, mesmo destino, janela de 5 minutos):
  - **Abordagem técnica (destaque do desafio):** window function `LAG(created_at) OVER (PARTITION BY amount, source_institution, destination_institution ORDER BY created_at)` e filtrar diferença ≤ 5 min; **ou** self-join com range temporal.
  - Discutir trade-off das duas abordagens no REPORT.
  - `EXPLAIN ANALYZE` antes/depois; índice composto `(source_institution, destination_institution, amount, created_at)` — justificar a ordem das colunas.

**Critério de aceitação:** Q3 e Q4 corretas; Q4 efetivamente encontra duplicatas plantadas no seed (garantir que existam); planos documentados.

**Atenção:** plantar alguns pares duplicados no seed (Sprint 01) ou aceitar os que a distribuição naturalmente gera — confirmar que Q4 retorna linhas.

**Artefatos:** `desafio-1/queries/Q3.sql`, `Q4.sql`.

---

## Story 2.5 — Série temporal com gapfill (48h)

**Descrição:** Query usando funções específicas do TimescaleDB para série contínua preenchendo lacunas.

**Tarefas:**
- Query de volume transacional por hora nas últimas 48h usando:
  - `time_bucket_gapfill('1 hour', created_at)` para gerar buckets contínuos (inclusive horas sem transação).
  - `locf()` (last observation carried forward) e/ou `interpolate()` para preencher lacunas — demonstrar ambas e explicar quando cada uma se aplica.
  - `COALESCE(count(*), 0)` para zerar buckets vazios onde fizer sentido.
- Comentar o caso de uso: dashboards não podem ter "buracos" no eixo temporal; gapfill resolve no banco em vez de no front.

**Critério de aceitação:** query retorna 48 buckets contínuos sem lacunas; uso de `locf`/`interpolate` demonstrado e explicado.

**Artefatos:** `desafio-1/queries/timeseries_gapfill_48h.sql`.

---

## Story 2.6 — Sanitização LGPD de chunks comprimidos

**Descrição:** Documentar (e demonstrar, se possível) como atender uma solicitação LGPD de exclusão de PII em dados comprimidos.

**Tarefas:**
- Explicar o **problema central:** chunks comprimidos são imutáveis — não se pode `UPDATE`/`DELETE` diretamente em dados comprimidos sem descomprimir.
- Documentar o procedimento:
  1. Identificar o(s) chunk(s) que contêm o dado-alvo (`show_chunks` com range temporal do registro).
  2. Descomprimir o chunk: `SELECT decompress_chunk('<chunk>');`
  3. Executar a exclusão/anonimização (`DELETE` ou `UPDATE` mascarando `holder_document`/`holder_name`/`metadata`).
  4. Recomprimir: `SELECT compress_chunk('<chunk>');`
  5. Validar e registrar (trilha de auditoria para conformidade).
- Discutir o **impacto operacional:** custo de descomprimir/recomprimir, janela de maior uso de storage temporário, e por que sanitização em lote (batch de solicitações) é preferível.
- Mencionar abordagem alternativa: separar PII em tabela não-comprimida referenciada por id (design para "right to be forgotten" mais barato) — registrar como recomendação de evolução.
- (Opcional, forte) demonstrar end-to-end num chunk de teste com contagem antes/depois.

**Critério de aceitação:** procedimento escrito, executável e justificado; impacto da compressão explicado.

**Artefatos:** `desafio-1/queries/lgpd_sanitization.sql`, seção `LGPD` no `REPORT.md`.

---

## Consolidação — REPORT.md

Ao final da sprint, o `desafio-1/REPORT.md` deve conter, para **cada** query: enunciado, índices criados (com justificativa), impacto do particionamento temporal, `EXPLAIN ANALYZE` comparativo (antes/depois) e comentários sobre o plano de execução (chunk exclusion, tipo de scan, custo estimado vs real, rows removidas por filtro).

---

## Riscos da Sprint

| Risco | Mitigação |
|---|---|
| CAgg não materializa (sem policy) | `add_continuous_aggregate_policy` + validação manual |
| EXPLAIN sem análise (só output cru) | Comentar cada plano: o que mudou e por quê |
| Q4 não encontra duplicatas | Plantar pares no seed ou confirmar geração natural |
| Retenção apaga dados antes do CAgg materializar | CAgg com retenção maior; ordem documentada |
| Stats desatualizadas distorcem EXPLAIN | `ANALYZE` após criar índices |

---

## Saída para a próxima sprint

Com TimescaleDB modelado, agregado e otimizado, o foco vira o legado (Sprint 03) e o ClickHouse (Sprint 04). `/compact` preservando: nomes dos CAggs, políticas ativas, índices criados e as decisões de otimização (serão citadas no ADR e na apresentação).

-- =============================================================================
--  Sprint 02 · Story 2.1 — CAgg B: liquidação por instituição, por dia
--
--  P95/P99 e a limitação central:
--  --------------------------------
--  `percentile_cont` é um ORDERED-SET AGGREGATE — exige o conjunto inteiro e
--  ordenado no momento da avaliação e NÃO possui estado parcial combinável.
--  Por isso o TimescaleDB PROÍBE ordered-set aggregates na definição de um
--  continuous aggregate (limitação independente de versão). O percentil
--  aproximado mergeável (`uddsketch`/`tdigest`) vive no TimescaleDB Toolkit, que
--  NÃO está disponível na imagem provisionada (`timescale/timescaledb:latest-pg16`
--  → `pg_available_extensions` não lista `timescaledb_toolkit`).
--
--  Decisão (defensável):
--    - Este CAgg materializa as ESTATÍSTICAS MERGEÁVEIS NATIVAS por
--      instituição/dia (count, soma, soma de latência, max de latência,
--      settled/failed). Serve a Q3 inteira (volume, latência média, taxa de
--      falha) por rollup barato.
--    - O P95/P99 EXATO é computado por query companheira
--      (../settlement_percentiles.sql) com chunk exclusion — exato, não
--      aproximado, ao custo de um sort por janela. Trade-off documentado no
--      REPORT; evolução de produção = Toolkit `uddsketch` (imagem `-ha`).
--
--  `avg` NÃO é materializado diretamente (média não é perfeitamente mergeável
--  via rollup sem peso): guardamos `sum_latency_s` + `settled_count` e dividimos
--  na leitura — matematicamente correto ao combinar buckets.
--
--  Bucket por `created_at`. A latência usa `settled_at`, que pode ser muito
--  posterior (boleto ~12h): a refresh policy (04) usa start_offset largo para
--  reprocessar buckets cujo status liquida tardiamente.
-- =============================================================================

CREATE MATERIALIZED VIEW IF NOT EXISTS cagg_settlement_by_institution_daily
WITH (timescaledb.continuous) AS
SELECT time_bucket('1 day', created_at)                       AS bucket,
       source_institution,
       count(*)                                               AS tx_count,
       count(*) FILTER (WHERE status = 'settled')             AS settled_count,
       count(*) FILTER (WHERE status = 'failed')              AS failed_count,
       sum(amount)                                            AS total_amount,
       sum(extract(epoch FROM (settled_at - created_at)))
           FILTER (WHERE status = 'settled')                  AS sum_latency_s,
       max(extract(epoch FROM (settled_at - created_at)))
           FILTER (WHERE status = 'settled')                  AS max_latency_s
FROM transactions
GROUP BY bucket, source_institution
WITH NO DATA;

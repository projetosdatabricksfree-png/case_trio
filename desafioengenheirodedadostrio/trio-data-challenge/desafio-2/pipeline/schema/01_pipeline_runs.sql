-- =============================================================================
--  Sprint 05 · Story 5.2 — Observabilidade do pipeline (uma linha por execução)
--
--  Cada run (--once ou uma volta do loop) registra métricas: linhas lidas/escritas,
--  lag origem-relativo, duração e status. Alimenta o DASHBOARD DE PIPELINE da
--  Sprint 06 (Grafana lê esta tabela via datasource ClickHouse já provisionado).
--
--  `lag_seconds` é RELATIVO À ORIGEM (max(effective_updated na origem) − watermark
--  sincronizado), não ao relógio de parede — o seed é estático, então freshness
--  vs. now() não teria sentido. Lag = 0 quando o pipeline alcançou a origem.
-- =============================================================================

CREATE TABLE IF NOT EXISTS trio_analytics.pipeline_runs
(
    run_id       UUID,
    pipeline     LowCardinality(String),
    started_at   DateTime64(3, 'UTC'),
    finished_at  DateTime64(3, 'UTC'),
    rows_read    UInt64,
    rows_written UInt64,
    lag_seconds  Float64,
    duration_ms  UInt64,
    status       LowCardinality(String),   -- ok | error
    error        String DEFAULT ''
)
ENGINE = MergeTree
ORDER BY (pipeline, started_at);

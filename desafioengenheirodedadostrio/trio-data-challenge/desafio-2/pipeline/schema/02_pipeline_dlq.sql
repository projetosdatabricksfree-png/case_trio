-- =============================================================================
--  Sprint 05 · Story 5.2 — Dead-letter queue do pipeline
--
--  Linhas/batches que falham repetidamente (após o retry com backoff exponencial)
--  são desviadas para cá com o payload original (JSON) e o motivo, em vez de
--  travar o pipeline ou serem perdidas silenciosamente. Permite inspeção e
--  reprocessamento manual. `retries` = nº de tentativas antes de desistir.
-- =============================================================================

CREATE TABLE IF NOT EXISTS trio_analytics.pipeline_dlq
(
    pipeline  LowCardinality(String),
    payload   String,                    -- registro original serializado (JSON)
    error     String,                    -- exceção/motivo da falha
    retries   UInt8,
    failed_at DateTime64(3, 'UTC') DEFAULT now64(3)
)
ENGINE = MergeTree
ORDER BY (pipeline, failed_at);

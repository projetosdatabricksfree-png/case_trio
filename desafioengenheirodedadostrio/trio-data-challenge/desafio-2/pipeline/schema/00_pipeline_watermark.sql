-- =============================================================================
--  Sprint 05 · Story 5.2 — Watermark do pipeline (estado de progresso)
--
--  Tabela de controle APPEND-ONLY: cada commit de batch insere uma linha com o
--  watermark efetivo alcançado. A leitura usa argMax((last_value,last_id),
--  committed_at) por pipeline — o último commit vence. Sem UPDATE/estado mutável
--  (idiomático no ClickHouse); idempotente e crash-safe: re-execução relê a
--  partir do último watermark confirmado e o ReplacingMergeTree da `transactions`
--  deduplica o que for reinserido.
--
--  Há um watermark por PASSADA do pipeline ts_to_ch (coluna `pipeline`):
--    - ts_to_ch_insert: `last_value` = limite superior de created_at já varrido
--      (janelas de tempo); `last_id` não usado (zero-uuid).
--    - ts_to_ch_mutate: `last_value`/`last_id` = keyset (settled_at, id) da última
--      mutação sincronizada.
--  PRECISÃO: DateTime64(6) = microssegundos, igual ao timestamptz do PostgreSQL —
--  sem isso, o truncamento p/ ms faria o keyset de mutação re-ler a linha de
--  fronteira indefinidamente (o dedup tornaria inócuo, mas o --once não convergiria).
-- =============================================================================

CREATE TABLE IF NOT EXISTS trio_analytics.pipeline_watermark
(
    pipeline       LowCardinality(String),
    last_value     DateTime64(6, 'UTC'),
    last_id        UUID,
    rows_committed UInt64,
    committed_at   DateTime64(3, 'UTC') DEFAULT now64(3)
)
ENGINE = MergeTree
ORDER BY (pipeline, committed_at);

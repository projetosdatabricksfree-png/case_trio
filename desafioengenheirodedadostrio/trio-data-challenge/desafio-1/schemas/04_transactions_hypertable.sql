-- =============================================================================
--  Sprint 01 · Story 1.2 — Converter transactions em hypertable
--
--  Particionamento por RANGE em `created_at` com chunk de 1 DIA:
--    - O padrão de consulta concentra-se nos últimos 30–90 dias → chunk
--      exclusion eficiente no planner.
--    - ~365 chunks/ano: equilíbrio entre granularidade (compressão de chunks
--      7+ dias, retenção de 90 dias na Sprint 02) e overhead de muitos chunks.
--    - Regra geral: o chunk deve caber confortavelmente em memória (~25% da RAM
--      como referência) — 1 dia de transações está muito abaixo disso.
--
--  SEM space partitioning adicional: neste volume (10M/ano, single-node) ele só
--  adiciona complexidade sem ganho de paralelismo real. Justificativa no REPORT.
--
--  IMPORTANTE: converter ANTES do seed massivo (migrar tabela já cheia é caro).
--  Idempotente via if_not_exists.
-- =============================================================================

SELECT create_hypertable(
    'transactions',
    by_range('created_at', INTERVAL '1 day'),
    if_not_exists => TRUE
);

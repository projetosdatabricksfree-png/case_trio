-- =============================================================================
--  Sprint 04 · Story 4.2 — MV A: resumo diário por instituição e tipo
--
--  Padrão MV + AggregatingMergeTree + States/Merge:
--    A MV dispara a cada INSERT na base e grava ESTADOS PARCIAIS de agregação
--    (countState/sumState/avgState/quantileState), não valores finais. O merge
--    em background combina os estados; a leitura aplica `-Merge` para finalizar.
--    Vantagem: agregados aditivos e exatos (incl. p95) sem reprocessar a base.
--
--  Caveat honesto (documentado no REPORT): a MV processa o BLOCO inserido, antes
--  do dedup do ReplacingMergeTree. Na carga estática desta sprint cada transação
--  entra UMA vez (estado final) -> agregados exatos. No pipeline contínuo (S05),
--  reinserir a mesma tx (pending->settled) contaria em dobro; mitigação lá.
-- =============================================================================

CREATE TABLE IF NOT EXISTS trio_analytics.tx_daily_summary
(
    day                Date,
    source_institution LowCardinality(String),
    type               LowCardinality(String),
    count_state        AggregateFunction(count),
    sum_state          AggregateFunction(sum, Decimal(18, 2)),
    avg_state          AggregateFunction(avg, Decimal(18, 2)),
    p95_state          AggregateFunction(quantile(0.95), Decimal(18, 2))
)
ENGINE = AggregatingMergeTree
PARTITION BY toYYYYMM(day)
ORDER BY (source_institution, type, day);

CREATE MATERIALIZED VIEW IF NOT EXISTS trio_analytics.mv_tx_daily_summary
TO trio_analytics.tx_daily_summary
AS
SELECT
    toDate(created_at)          AS day,
    source_institution,
    type,
    countState()                AS count_state,
    sumState(amount)            AS sum_state,
    avgState(amount)            AS avg_state,
    quantileState(0.95)(amount) AS p95_state
FROM trio_analytics.transactions
GROUP BY day, source_institution, type;

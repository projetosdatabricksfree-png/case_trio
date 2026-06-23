-- =============================================================================
--  Sprint 04 · Story 4.2 — MV B: funil de status + tempo de liquidação
--
--  Distribuição por estágio do funil (pending -> settled/failed/reversed) e tempo
--  médio até a liquidação. O ClickHouse não tem UPDATE; o "funil" é derivado da
--  versão corrente de cada transação (status + created_at + settled_at).
--
--  avgStateIf(..., isNotNull(settled_at)) calcula a latência só onde houve
--  liquidação (pending/failed não têm settled_at). `assumeNotNull` remove o
--  Nullable DENTRO do ramo filtrado -> o estado é AggregateFunction(avg, Float64),
--  casando com a coluna-alvo (sem Nullable no tipo do estado).
-- =============================================================================

CREATE TABLE IF NOT EXISTS trio_analytics.tx_status_funnel
(
    day               Date,
    type              LowCardinality(String),
    status            LowCardinality(String),
    count_state       AggregateFunction(count),
    avg_latency_state AggregateFunction(avg, Float64)
)
ENGINE = AggregatingMergeTree
PARTITION BY toYYYYMM(day)
ORDER BY (type, status, day);

CREATE MATERIALIZED VIEW IF NOT EXISTS trio_analytics.mv_tx_status_funnel
TO trio_analytics.tx_status_funnel
AS
SELECT
    toDate(created_at) AS day,
    type,
    status,
    countState()       AS count_state,
    avgStateIf(
        toFloat64(dateDiff('second', created_at, assumeNotNull(settled_at))),
        isNotNull(settled_at)
    )                  AS avg_latency_state
FROM trio_analytics.transactions
GROUP BY day, type, status;

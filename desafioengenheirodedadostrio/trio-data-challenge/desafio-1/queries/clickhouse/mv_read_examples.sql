-- =============================================================================
--  Sprint 04 · Story 4.2 — Leitura das MVs com funções -Merge
--
--  As MVs gravam ESTADOS de agregação (countState/sumState/avgState/quantileState).
--  A leitura finaliza com -Merge. Combinar estados é barato -> dashboards leem
--  agregados (incl. p95) sem reprocessar a base.
-- =============================================================================

-- MV A — resumo diário por instituição/tipo (top 10 por volume), nome via dictGet.
SELECT
    dictGet('trio_analytics.dict_institutions', 'institution_name', source_institution) AS institution,
    type,
    countMerge(count_state)                   AS tx,
    round(sumMerge(sum_state), 2)             AS total_amount,
    round(avgMerge(avg_state), 2)             AS avg_amount,
    round(quantileMerge(0.95)(p95_state), 2)  AS p95_amount
FROM trio_analytics.tx_daily_summary
GROUP BY source_institution, type
ORDER BY tx DESC
LIMIT 10;

-- MV B — funil de status por tipo + tempo médio até liquidar (s).
-- pending/failed não têm settled_at -> avgMerge sobre conjunto vazio = nan
-- (sem tempo de liquidação), explicitado como NULL via nullIf(isNaN()).
SELECT
    type,
    status,
    countMerge(count_state)                                          AS tx,
    if(isNaN(avgMerge(avg_latency_state)), NULL,
       round(avgMerge(avg_latency_state), 1))                        AS avg_settle_seconds
FROM trio_analytics.tx_status_funnel
GROUP BY type, status
ORDER BY type, tx DESC;

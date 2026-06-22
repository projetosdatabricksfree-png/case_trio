-- =============================================================================
--  Sprint 02 · Q3 — Top 20 instituições por volume (90 dias) + latência média
--                   de liquidação + taxa de falha
--
--  Otimização: servida do CAgg B (cagg_settlement_by_institution_daily). Todas
--  as métricas são mergeáveis nativas:
--    - volume         = sum(total_amount)
--    - latência média = sum(sum_latency_s) / sum(settled_count)   (correto ao
--                       combinar buckets; por isso NÃO materializamos avg direto)
--    - taxa de falha  = sum(failed_count) / sum(tx_count)
--  Rollup de ~90 dias x 30 instituições = ~2.700 linhas do agregado, contra
--  ~2,5M linhas do raw (90 chunks).
--
--  P95/P99 (tail) ficam na query exata companheira settlement_percentiles.sql
--  (percentile_cont não cabe em CAgg — ver 02_cagg_...sql).
-- =============================================================================

SELECT c.source_institution,
       i.short_name,
       sum(c.total_amount)                                                 AS volume,
       round(sum(c.sum_latency_s) / NULLIF(sum(c.settled_count), 0), 1)    AS avg_latency_s,
       round(100.0 * sum(c.failed_count) / NULLIF(sum(c.tx_count), 0), 2)  AS failure_rate_pct
FROM cagg_settlement_by_institution_daily c
LEFT JOIN institutions i ON i.institution_code = c.source_institution
WHERE c.bucket >= now() - INTERVAL '90 days'
GROUP BY c.source_institution, i.short_name
ORDER BY volume DESC
LIMIT 20;

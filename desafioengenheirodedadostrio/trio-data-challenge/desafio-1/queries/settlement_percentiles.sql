-- =============================================================================
--  Sprint 02 · Companheira do CAgg B — P95/P99 EXATOS de latência (90 dias)
--
--  percentile_cont é ordered-set aggregate → não cabe em continuous aggregate.
--  O Toolkit (uddsketch/approx_percentile) não está na imagem provisionada.
--  Decisão: tail exato aqui, com chunk exclusion (created_at >= now()-90d)
--  limitando o scan; o custo é um sort por grupo (aceitável p/ query analítica).
--  Produção: materializar uddsketch no CAgg (imagem -ha) elimina o sort.
-- =============================================================================

SELECT source_institution,
       count(*)                                                                 AS settled,
       round((percentile_cont(0.95) WITHIN GROUP (
               ORDER BY extract(epoch FROM (settled_at - created_at))))::numeric, 1) AS p95_latency_s,
       round((percentile_cont(0.99) WITHIN GROUP (
               ORDER BY extract(epoch FROM (settled_at - created_at))))::numeric, 1) AS p99_latency_s
FROM transactions
WHERE created_at >= now() - INTERVAL '90 days'
  AND status = 'settled'
GROUP BY source_institution
ORDER BY p99_latency_s DESC;

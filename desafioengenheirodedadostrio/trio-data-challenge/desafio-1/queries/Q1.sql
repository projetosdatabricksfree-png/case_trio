-- =============================================================================
--  Sprint 02 · Q1 — Volume e valor por TIPO e STATUS, por mês, últimos 6 meses
--
--  Otimização: servida do CAgg A (cagg_volume_by_type_hourly), que já inclui
--  `status`. O rollup horário->mensal é uma soma sobre ~poucos milhares de linhas
--  do agregado, em vez de varrer ~5M linhas do raw (6 meses de chunks).
--
--  EXPLAIN antes/depois no REPORT: o baseline (raw) faz ChunkAppend + Parallel
--  Seq Scan + HashAggregate sobre ~180 chunks; a versão do CAgg lê só o
--  hypertable de materialização (ordens de grandeza menos linhas e buffers).
-- =============================================================================

SELECT time_bucket('1 month', bucket) AS month,
       type,
       status,
       sum(tx_count)     AS tx_count,
       sum(total_amount) AS total_amount
FROM cagg_volume_by_type_hourly
WHERE bucket >= date_trunc('month', now()) - INTERVAL '6 months'
GROUP BY month, type, status
ORDER BY month, type, status;

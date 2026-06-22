-- =============================================================================
--  Sprint 02 · Story 2.5 — Série temporal por hora (48h) com gapfill
--
--  time_bucket_gapfill GERA os buckets ausentes (horas sem transação), que sem
--  ele sumiriam do GROUP BY e deixariam "buracos" no eixo do dashboard.
--
--  Três tratamentos lado a lado para a MESMA métrica (count por hora):
--    - coalesce(count(*),0) : volume é métrica de FLUXO → gap = ZERO real.
--                             Esta é a coluna correta para o painel.
--    - locf(count(*))       : carrega o último valor (degrau). Correto para
--                             métricas de NÍVEL/estado, não para fluxo.
--    - interpolate(count(*)): reta entre vizinhos (rampa). Correto para sinais
--                             contínuos amostrados; para volume inventa rampa.
--  Demonstra a diferença visual/semântica (zeros honestos vs degrau vs rampa).
--
--  WHERE com limites de tempo explícitos é exigido pelo gapfill p/ saber as
--  bordas. Retorna 48 buckets contínuos.
-- =============================================================================

SELECT time_bucket_gapfill('1 hour', created_at) AS bucket,
       coalesce(count(*), 0)                      AS tx_count_zero,
       locf(count(*))                             AS tx_count_locf,
       interpolate(count(*))                      AS tx_count_interp,
       coalesce(sum(amount), 0)                   AS total_amount
FROM transactions
WHERE created_at >= date_trunc('hour', now()) - INTERVAL '48 hours'
  AND created_at <  date_trunc('hour', now())
GROUP BY bucket
ORDER BY bucket;

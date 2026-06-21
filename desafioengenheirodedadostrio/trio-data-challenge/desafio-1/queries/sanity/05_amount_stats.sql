-- Sanidade: estatísticas de valor. Esperado de log-normal: média > mediana
-- (cauda à direita) e p95/max bem acima da mediana.
SELECT count(*)                                                            AS n,
       min(amount)                                                         AS min_amount,
       round((percentile_cont(0.5)  WITHIN GROUP (ORDER BY amount))::numeric, 2)  AS median,
       round(avg(amount), 2)                                               AS avg_amount,
       round((percentile_cont(0.95) WITHIN GROUP (ORDER BY amount))::numeric, 2)  AS p95,
       max(amount)                                                         AS max_amount
FROM transactions;

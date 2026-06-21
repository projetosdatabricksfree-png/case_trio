-- Sanidade: latência média de liquidação por tipo (só transações liquidadas).
-- Esperado: Pix segundos; cartão segundos/minutos; TED minutos; boleto horas.
SELECT type,
       count(*) FILTER (WHERE settled_at IS NOT NULL)                          AS settled,
       round(avg(extract(epoch FROM (settled_at - created_at)))
             FILTER (WHERE settled_at IS NOT NULL)::numeric, 1)               AS avg_latency_s
FROM transactions
GROUP BY type
ORDER BY avg_latency_s;

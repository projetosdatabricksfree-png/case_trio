-- Sanidade: distribuição de status. Esperado: settled ~90%, e frações menores
-- de pending/failed/reversed.
SELECT status,
       count(*)                                              AS n,
       round(100.0 * count(*) / sum(count(*)) OVER (), 2)    AS pct
FROM transactions
GROUP BY status
ORDER BY n DESC;

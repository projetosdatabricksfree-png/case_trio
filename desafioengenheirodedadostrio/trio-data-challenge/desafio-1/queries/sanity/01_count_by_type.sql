-- Sanidade: total e mix por tipo. Esperado: Pix dominante (~70%), depois
-- cartão (~15%), TED (~10%) e boleto (~5%).
SELECT type,
       count(*)                                              AS n,
       round(100.0 * count(*) / sum(count(*)) OVER (), 2)    AS pct
FROM transactions
GROUP BY type
ORDER BY n DESC;

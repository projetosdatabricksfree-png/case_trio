-- Sanidade: volume por dia da semana. Esperado: dias úteis (seg–sex) bem acima
-- de sábado/domingo. dow: 0=domingo .. 6=sábado.
SELECT extract(dow FROM created_at)::int  AS dow,
       to_char(created_at, 'Dy')          AS weekday,
       count(*)                           AS n
FROM transactions
GROUP BY dow, weekday
ORDER BY dow;

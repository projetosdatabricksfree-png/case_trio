-- Sanidade: volume por hora do dia. Esperado: pico em horário comercial,
-- vale na madrugada.
SELECT extract(hour FROM created_at)::int  AS hour,
       count(*)                            AS n
FROM transactions
GROUP BY hour
ORDER BY hour;

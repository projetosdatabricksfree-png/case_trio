-- Sanidade: eventos de conciliação por tipo e nº de divergências (|difference|
-- > 0,01). Garante que existem casos divergentes para a Q2 da Sprint 02.
SELECT event_type,
       count(*)                                          AS n,
       count(*) FILTER (WHERE abs(difference) > 0.01)    AS divergent,
       round(sum(difference), 2)                         AS sum_difference
FROM reconciliation_events
GROUP BY event_type
ORDER BY n DESC;

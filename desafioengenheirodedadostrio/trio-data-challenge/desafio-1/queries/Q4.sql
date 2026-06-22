-- =============================================================================
--  Sprint 02 · Q4 — Detecção de duplicatas (mesmo valor, origem, destino,
--                   janela de 5 minutos)
--
--  Abordagem: WINDOW FUNCTION (LAG), não self-join temporal.
--    - LAG: passe único O(n), memória limitada (streaming). Com o índice
--      composto (amount, source, destination, created_at), as 3 chaves de
--      igualdade casam a PARTITION e created_at fornece a ORDER → o plano
--      ELIMINA o Sort (MergeAppend ordenado alimenta o WindowAgg).
--    - Self-join temporal acharia todos os pares, mas é range join com risco
--      O(n^2) em chaves quentes (densas). LAG remove o pior caso por design;
--      pega pares consecutivos, suficiente para flag de duplicata.
--
--  Escopada a 7 dias → chunk exclusion limita aos chunks recentes.
-- =============================================================================

WITH windowed AS (
    SELECT id,
           created_at,
           amount,
           source_institution,
           destination_institution,
           lag(created_at) OVER (
               PARTITION BY amount, source_institution, destination_institution
               ORDER BY created_at
           ) AS prev_created_at
    FROM transactions
    WHERE created_at >= now() - INTERVAL '7 days'
)
SELECT amount,
       source_institution,
       destination_institution,
       prev_created_at,
       created_at,
       created_at - prev_created_at AS gap
FROM windowed
WHERE prev_created_at IS NOT NULL
  AND created_at - prev_created_at <= INTERVAL '5 minutes'
ORDER BY amount, source_institution, destination_institution, created_at
LIMIT 100;

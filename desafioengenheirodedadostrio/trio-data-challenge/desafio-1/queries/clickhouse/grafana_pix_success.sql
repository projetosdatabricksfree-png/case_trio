-- =============================================================================
--  Sprint 04 · Story 4.4 — Query Grafana (destaque): sucesso Pix por instituição
--  por hora nas últimas 24h + delta % vs o mesmo horário do dia anterior.
--
--  Sub-segundo em centenas de milhões: a janela de 48h + type='pix' são altamente
--  seletivos. PARTITION BY toYYYYMM poda p/ 1-2 partes; o ORDER BY
--  (source_institution, type, created_at, id) poda granules dentro de cada prefixo
--  (instituição, pix) -> só ~0,5% das linhas são lidas. Servida da tabela RAW
--  (não precisa de MV): a poda do índice primário já entrega o tempo-alvo.
--
--  Âncora = max(created_at) (NÃO now()): o seed é estático, então "24h/48h" é
--  relativo ao último dado carregado. dictGet enriquece o nome sem JOIN.
--  delta_pct = variação relativa da taxa de sucesso vs ontem (nullIf evita /0);
--  success_pct_* mostram as taxas absolutas para contexto.
-- =============================================================================

WITH (SELECT max(created_at) FROM trio_analytics.transactions) AS t_max
SELECT
    dictGet('trio_analytics.dict_institutions', 'institution_name', t.source_institution) AS institution,
    t.hour                                                          AS hour,
    t.n                                                             AS tx_today,
    round(100 * t.success_rate, 2)                                 AS success_pct_today,
    round(100 * y.success_rate, 2)                                 AS success_pct_yesterday,
    round(100 * (t.success_rate - y.success_rate) / nullIf(y.success_rate, 0), 1) AS delta_pct
FROM
(
    SELECT
        source_institution,
        toStartOfHour(created_at)         AS hour,
        count()                           AS n,
        countIf(status = 'settled') / count() AS success_rate
    FROM trio_analytics.transactions
    WHERE type = 'pix'
      AND created_at > t_max - INTERVAL 24 HOUR
    GROUP BY source_institution, hour
) AS t
LEFT JOIN
(
    SELECT
        source_institution,
        toStartOfHour(created_at)         AS hour,
        countIf(status = 'settled') / count() AS success_rate
    FROM trio_analytics.transactions
    WHERE type = 'pix'
      AND created_at > t_max - INTERVAL 48 HOUR
      AND created_at <= t_max - INTERVAL 24 HOUR
    GROUP BY source_institution, hour
) AS y
    ON t.source_institution = y.source_institution
   AND t.hour = y.hour + INTERVAL 24 HOUR
ORDER BY institution, hour
SETTINGS join_use_nulls = 1;

-- =============================================================================
--  Sprint 04 · Story 4.3 — Dictionary em uso (dictGet) vs JOIN
--
--  dictGet faz lookup O(1) em memória (layout complex_key_hashed) — sem hash join,
--  sem ler a tabela de referência do disco. Ideal p/ dados de referência de baixa
--  cardinalidade (~30 instituições) que mudam pouco. JOIN só compensaria p/ tabelas
--  grandes/voláteis. Enriquece nome, janela de liquidação e tipo num só passo.
-- =============================================================================

SELECT
    source_institution                                                              AS code,
    dictGet('trio_analytics.dict_institutions', 'institution_name', source_institution)  AS institution_name,
    dictGet('trio_analytics.dict_institutions', 'settlement_window', source_institution) AS settlement_window,
    dictGet('trio_analytics.dict_institutions', 'type', source_institution)              AS institution_type,
    count()                                                                         AS pix_tx
FROM trio_analytics.transactions
WHERE type = 'pix'
GROUP BY source_institution
ORDER BY pix_tx DESC
LIMIT 10;

-- =============================================================================
--  Sprint 02 · Story 2.2 — Compressão de chunks (7+ dias)
--
--  segmentby = (type, source_institution): colunas usadas em filtros/agrupamentos
--    (Q1, Q3) → cada segmento é armazenado em separado, permitindo exclusão de
--    segmento sem descomprimir. Trade-off medido no REPORT: type(4) x
--    instituição(30) = ~120 segmentos/chunk; com ~27k linhas/chunk diário dá
--    ~228 linhas/segmento (abaixo do batch de 1000 → razão de compressão menor).
--    Mantido conforme a story; alternativa `segmentby=type` discutida no REPORT.
--  orderby = created_at DESC: maximiza encoding delta/run-length no tempo, grava
--    min/max por batch (exclusão de batch por created_at dentro do chunk) e serve
--    ORDER BY created_at DESC LIMIT sem descomprimir-e-ordenar.
--
--  Compressão NÃO apaga dados — só transforma o armazenamento (append-friendly):
--    leitura histórica fica mais barata; update/delete pontual fica mais caro
--    (ver runbook LGPD).
-- =============================================================================

ALTER TABLE transactions SET (
    timescaledb.compress,
    timescaledb.compress_orderby   = 'created_at DESC',
    timescaledb.compress_segmentby = 'type, source_institution'
);

SELECT add_compression_policy('transactions', INTERVAL '7 days', if_not_exists => TRUE);

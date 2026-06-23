-- =============================================================================
--  Sprint 05 · Story 5.2/5.3 — Índice da passada de MUTAÇÃO (no TimescaleDB)
--
--  A origem é uma hypertable COMPRIMIDA (política da Sprint 02). O pipeline lê em
--  duas passadas:
--    - INSERT pass: janela de tempo sobre `created_at` (coluna de partição/orderby
--      da compressão) -> poda de chunk nativa, SEM índice extra e SEM Sort global.
--    - MUTATE pass: keyset `(settled_at, id)` p/ captar pending -> settled.
--
--  Este índice apoia a MUTATE pass: `(settled_at, id)` cobre a leitura ordenada das
--  linhas recém-liquidadas (chunks não comprimidos / recentes). Em chunks
--  comprimidos o filtro vira ColumnarScan — aceitável: o conjunto de mutações é
--  pequeno (o watermark inicia em max(settled_at), então só pega mutações futuras).
--  Aplicado PÓS-SEED (não pesa o COPY). Em produção, CDC lê o WAL e dispensa isto.
-- =============================================================================

CREATE INDEX IF NOT EXISTS idx_tx_settled_id
    ON transactions (settled_at, id);

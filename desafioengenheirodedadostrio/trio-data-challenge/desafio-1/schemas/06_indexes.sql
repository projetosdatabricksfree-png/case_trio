-- =============================================================================
--  Sprint 01 · Story 1.4 — Índices secundários de transactions (PÓS-SEED)
--
--  Aplicados DEPOIS da carga (`make index`), nunca durante o COPY: manter só a
--  PK durante o load preserva o throughput; construir os índices de uma vez ao
--  final é mais rápido que mantê-los linha a linha (boa prática de bulk load).
--
--  Cobrem os filtros quentes das queries Q1–Q4 da Sprint 02. O TimescaleDB
--  propaga cada índice para todos os chunks da hypertable.
-- =============================================================================

-- Unicidade de external_id (idempotência de ingestão — pipeline da Sprint 05).
CREATE UNIQUE INDEX IF NOT EXISTS idx_tx_external
    ON transactions (external_id, created_at);

-- Volume/valor por tipo ao longo do tempo (CAgg (a) da Sprint 02).
CREATE INDEX IF NOT EXISTS idx_tx_type_created
    ON transactions (type, created_at DESC);

-- Distribuição/funil de status.
CREATE INDEX IF NOT EXISTS idx_tx_status
    ON transactions (status);

-- Latência de liquidação e volume por instituição (CAgg (b) da Sprint 02).
CREATE INDEX IF NOT EXISTS idx_tx_src_inst
    ON transactions (source_institution, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_tx_dst_inst
    ON transactions (destination_institution, created_at DESC);

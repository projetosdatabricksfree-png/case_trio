-- =============================================================================
--  Sprint 02 · Story 2.1 — Materialização inicial dos CAggs
--
--  `CALL refresh_continuous_aggregate` NÃO pode rodar dentro de um bloco de
--  transação — por isso fica em arquivo separado (psql roda cada CALL em sua
--  própria transação implícita). Janela explícita cobrindo todo o seed
--  (12 meses); a partir daqui a refresh policy (04) mantém o agregado vivo.
-- =============================================================================

CALL refresh_continuous_aggregate('cagg_volume_by_type_hourly',           '2025-06-01', '2026-06-22');
CALL refresh_continuous_aggregate('cagg_settlement_by_institution_daily',  '2025-06-01', '2026-06-22');

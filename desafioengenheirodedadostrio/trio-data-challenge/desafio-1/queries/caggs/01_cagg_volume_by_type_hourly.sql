-- =============================================================================
--  Sprint 02 · Story 2.1 — CAgg A: volume e valor por tipo+status, por hora
--
--  Decisão: além de `type` (pedido na story), o GROUP BY inclui `status`.
--  Motivo: a Q1 da Sprint 02 pede volume/valor por tipo E status — incluir
--  `status` no CAgg permite servir a Q1 inteiramente do agregado materializado
--  (rollup horário -> mensal), sem tocar o raw. Cardinalidade extra é trivial
--  (4 tipos x 4 status = 16 combinações/hora).
--
--  count(*) e sum(amount) são agregados PARCIAIS combináveis: o CAgg guarda o
--  estado por bucket horário e o rollup para mês/dia é só uma soma — barato e
--  sem reler o raw.
--
--  WITH NO DATA: criação não materializa (sem lock longo na criação). A carga
--  inicial é feita por refresh explícito (03_cagg_refresh.sql); a policy
--  (04_cagg_policies.sql) mantém o agregado atualizado dali em diante.
-- =============================================================================

CREATE MATERIALIZED VIEW IF NOT EXISTS cagg_volume_by_type_hourly
WITH (timescaledb.continuous) AS
SELECT time_bucket('1 hour', created_at) AS bucket,
       type,
       status,
       count(*)    AS tx_count,
       sum(amount) AS total_amount
FROM transactions
GROUP BY bucket, type, status
WITH NO DATA;

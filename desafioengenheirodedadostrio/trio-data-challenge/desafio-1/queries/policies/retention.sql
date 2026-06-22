-- =============================================================================
--  Sprint 02 · Story 2.2 — Retenção (raw 90d, CAggs 2 anos)
--
--  Padrão downsample-and-keep: o raw guarda 90 dias para forense granular; os
--  CAggs guardam 2 anos para tendência/SLA em menor resolução. Os CAggs
--  materializam numa hypertable SEPARADA — quando a retenção dropa o chunk bruto
--  (drop de chunk, atômico e barato), o dado já materializado no CAgg PERMANECE.
--  Segurança: a retenção raw (90d) só é segura porque a refresh policy já
--  materializou o histórico, e a retenção do CAgg (2a) > retenção raw.
--
--  GUARD DE DEMO: a retenção RAW é registrada (aparece em timescaledb_information
--  .jobs) porém PAUSADA neste ambiente autocontido, para que os 12 meses de seed
--  sobrevivam à defesa ao vivo. Em PRODUÇÃO, remover o último bloco (a policy
--  roda no schedule_interval padrão, 1 dia).
-- =============================================================================

SELECT add_retention_policy('transactions',                          INTERVAL '90 days', if_not_exists => TRUE);
SELECT add_retention_policy('cagg_volume_by_type_hourly',            INTERVAL '2 years', if_not_exists => TRUE);
SELECT add_retention_policy('cagg_settlement_by_institution_daily',  INTERVAL '2 years', if_not_exists => TRUE);

-- DEMO GUARD (remover em produção): pausa SÓ a retenção raw de transactions.
SELECT alter_job(job_id, scheduled => FALSE)
FROM timescaledb_information.jobs
WHERE proc_name = 'policy_retention'
  AND hypertable_name = 'transactions';

-- =============================================================================
--  Sprint 06 · Story 6.3 — Validação READ-ONLY do runbook de storage.
--
--  Seguro ao vivo: NÃO remove nem altera nada. Confirma as pré-condições antes
--  de qualquer `drop_chunks` (ver desafio-3/runbook.md §2). Roda via
--  `make runbook-storage-check`. ON_ERROR_STOP no caller valida a execução.
-- =============================================================================

\echo '== 1) Tamanho atual (linha de base do "92%") =='
SELECT pg_size_pretty(hypertable_size('transactions'))      AS hypertable,
       pg_size_pretty(pg_database_size(current_database()))  AS database;

\echo '== 2) Chunks-alvo (> 6 meses) e estado de compressão =='
SELECT count(*) FILTER (WHERE is_compressed)     AS comprimidos,
       count(*) FILTER (WHERE NOT is_compressed) AS nao_comprimidos,
       count(*)                                  AS total_alvo
  FROM timescaledb_information.chunks
 WHERE hypertable_name = 'transactions'
   AND range_end < now() - INTERVAL '6 months';

\echo '== 3) Cobertura dos CAggs sobre o período (histórico já materializado?) =='
SELECT 'cagg_volume_by_type_hourly' AS cagg,
       min(bucket)::text AS bucket_min, max(bucket)::text AS bucket_max
  FROM cagg_volume_by_type_hourly
UNION ALL
SELECT 'cagg_settlement_by_institution_daily',
       min(bucket)::text, max(bucket)::text
  FROM cagg_settlement_by_institution_daily;

\echo '== 4) Jobs de compressão/retenção (saúde) =='
SELECT j.job_id, j.proc_name, j.scheduled,
       s.last_run_status, s.last_successful_finish
  FROM timescaledb_information.jobs j
  LEFT JOIN timescaledb_information.job_stats s USING (job_id)
 WHERE j.hypertable_name = 'transactions'
 ORDER BY j.job_id;

\echo 'OK: validação read-only concluída (nada foi alterado).'

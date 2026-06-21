-- =============================================================================
--  Sprint 01 · Story 1.1 — Extensões necessárias
--
--  Idempotente e self-contained: espelha init/timescaledb/00_init.sql para que
--  `make migrate` funcione mesmo num banco onde os scripts de init/ não tenham
--  rodado (ex.: volume pré-existente). Roda primeiro por ordem lexical.
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS timescaledb;

CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

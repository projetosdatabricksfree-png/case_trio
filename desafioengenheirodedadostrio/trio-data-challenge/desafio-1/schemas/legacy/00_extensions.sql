-- =============================================================================
--  Sprint 03 · Story 3.1 — Extensões do legado (trio_legado)
--
--  Self-contained (espelha init/postgres-legado/00_init.sql): permite reaplicar o
--  schema com `make migrate-legado` sem depender do volume vazio do container.
--  pg_stat_statements já está em shared_preload_libraries (docker-compose) — aqui
--  só registramos a extensão no banco para corroborar os ganhos das queries.
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

-- =============================================================================
--  Sprint 04 · ClickHouse — Database (idempotente, aplicado por `make migrate-ch`)
--
--  O DDL do ClickHouse NÃO mora em init/ (que só roda na 1ª criação do volume e
--  não pode depender do postgres-legado já populado, exigido pelo dictionary).
--  Mora aqui e é aplicado por `make migrate-ch` — mesma filosofia de migrate/
--  migrate-legado: idempotente e re-executável sem `down -v`.
-- =============================================================================

CREATE DATABASE IF NOT EXISTS trio_analytics;

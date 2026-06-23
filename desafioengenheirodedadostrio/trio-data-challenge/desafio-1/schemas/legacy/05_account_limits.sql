-- =============================================================================
--  Sprint 03 · Story 3.1 — Limites operacionais por conta: account_limits
--
--  Relação 1:1 com `accounts` (UNIQUE em account_id). Enriquece o join da Story
--  3.3 (filtro `balance > daily_limit`). A FK em `account_id` é UNIQUE — o índice
--  único nasce com a constraint, então o join account_limits<->accounts já é
--  indexado por construção (diferente das FKs "cruas" de accounts/partners).
-- =============================================================================

CREATE TABLE IF NOT EXISTS account_limits (
    account_id    bigint        NOT NULL UNIQUE REFERENCES accounts (id),
    daily_limit   numeric(18,2) NOT NULL DEFAULT 0 CHECK (daily_limit >= 0),
    monthly_limit numeric(18,2) NOT NULL DEFAULT 0 CHECK (monthly_limit >= 0),
    per_tx_limit  numeric(18,2) NOT NULL DEFAULT 0 CHECK (per_tx_limit >= 0),
    updated_at    timestamptz   NOT NULL DEFAULT now()
);

-- =============================================================================
--  Sprint 01 · Story 1.1 — Tabela de referência: institutions
--
--  Single Source of Truth (SSOT) do universo de instituições. Reusada por
--  `accounts` (FK) e `transactions` (soft-ref por institution_code), e exportada
--  para o dictionary do ClickHouse na Sprint 04 (institution_code -> name).
--
--  Domínio pequeno e estável → tabela de referência + CHECK no `type`, em vez de
--  ENUM nativo (que tornaria a evolução de valores custosa: lock, sem DROP VALUE).
-- =============================================================================

CREATE TABLE IF NOT EXISTS institutions (
    institution_code  text PRIMARY KEY,            -- código no padrão ISPB (8 dígitos)
    name              text        NOT NULL,
    short_name        text        NOT NULL,
    type              text        NOT NULL
        CHECK (type IN ('bank', 'fintech', 'payment_institution', 'credit_union')),
    created_at        timestamptz NOT NULL DEFAULT now()
);

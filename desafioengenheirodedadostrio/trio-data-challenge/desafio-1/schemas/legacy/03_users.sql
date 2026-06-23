-- =============================================================================
--  Sprint 03 · Story 3.1 — Titulares do legado: users
--
--  PII (`document` = CPF/CNPJ, `full_name`) CONFINADA a esta dimensão — coerente
--  com o padrão de vault da Sprint 02 (esquecimento LGPD é UPDATE/DELETE indexado
--  por id, sem tocar nas tabelas grandes).
--
--  Chave `bigint GENERATED ALWAYS AS IDENTITY` (legacy smell — ver
--  02_institution_partners.sql).
-- =============================================================================

CREATE TABLE IF NOT EXISTS users (
    id          bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    full_name   text        NOT NULL,        -- PII
    document    text        NOT NULL,        -- PII (CPF/CNPJ)
    email       text        NOT NULL,
    status      text        NOT NULL DEFAULT 'active'
        CHECK (status IN ('active', 'suspended', 'closed')),
    created_at  timestamptz NOT NULL DEFAULT now()
);

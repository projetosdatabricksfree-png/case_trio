-- =============================================================================
--  Sprint 01 · Story 1.1 — Tabela dimensão: accounts
--
--  Contas titulares das transações. `holder_document` (CPF/CNPJ) e `holder_name`
--  são PII → alvo do procedimento de sanitização LGPD (RF-1.8, Sprint 02).
--
--  Tabela regular (não-hypertable): cardinalidade moderada (dezenas de milhares),
--  sem dimensão temporal de série. FK normal para `institutions` (dimensão pequena,
--  custo de manutenção desprezível neste volume).
-- =============================================================================

CREATE TABLE IF NOT EXISTS accounts (
    id                uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    account_number    text        NOT NULL,
    institution_code  text        NOT NULL REFERENCES institutions (institution_code),
    holder_document   text        NOT NULL,        -- PII (CPF/CNPJ)
    holder_name       text        NOT NULL,        -- PII
    account_type      text        NOT NULL
        CHECK (account_type IN ('checking', 'savings', 'payment')),
    status            text        NOT NULL DEFAULT 'active'
        CHECK (status IN ('active', 'blocked', 'closed')),
    created_at        timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_accounts_institution
    ON accounts (institution_code);

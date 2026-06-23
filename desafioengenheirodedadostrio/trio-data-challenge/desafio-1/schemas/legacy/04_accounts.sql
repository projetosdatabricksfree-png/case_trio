-- =============================================================================
--  Sprint 03 · Story 3.1 — Contas do legado: accounts
--
--  Tabela "quente" do legado (centenas de milhares de linhas): titular (user_id),
--  instituição (institution_code) e `balance`. É o alvo da Story 3.2 (relatório de
--  contas ativas) e o centro do join da Story 3.3.
--
--  Chave `bigint IDENTITY` (legacy smell). As FKs (`user_id`, `institution_code`)
--  ficam SEM índice de apoio aqui — o "antes" do EXPLAIN evidencia Seq Scan e join
--  por hash sem índice; os índices entram em 06_indexes_legacy.sql (pós-seed).
-- =============================================================================

CREATE TABLE IF NOT EXISTS accounts (
    id                bigint        GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id           bigint        NOT NULL REFERENCES users (id),
    institution_code  text          NOT NULL REFERENCES institution_configs (institution_code),
    account_number    text          NOT NULL,
    account_type      text          NOT NULL
        CHECK (account_type IN ('checking', 'savings', 'payment')),
    status            text          NOT NULL DEFAULT 'active'
        CHECK (status IN ('active', 'blocked', 'closed')),
    balance           numeric(18,2) NOT NULL DEFAULT 0,
    created_at        timestamptz   NOT NULL DEFAULT now(),
    updated_at        timestamptz   NOT NULL DEFAULT now()
);

-- =============================================================================
--  Sprint 03 · Story 3.1 — Parcerias por instituição: institution_partners
--
--  Enriquece o join da Story 3.3 (acordos de adquirência/emissão/correspondente).
--  Chave `bigint GENERATED ALWAYS AS IDENTITY` — "cheiro de legado" deliberado
--  (surrogate sequencial) que contrasta com o UUID do schema moderno e alimenta o
--  migration-analysis.md (sequências/IDENTITY = pegadinha de DMS/replicação lógica).
--
--  A FK em `institution_code` NÃO recebe índice de apoio aqui de propósito: o
--  Postgres não indexa FK automaticamente, então o "antes" do EXPLAIN mostra o
--  custo do join sem índice; o índice entra em 06_indexes_legacy.sql (pós-seed).
-- =============================================================================

CREATE TABLE IF NOT EXISTS institution_partners (
    id                bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    institution_code  text        NOT NULL REFERENCES institution_configs (institution_code),
    partner_name      text        NOT NULL,
    partnership_type  text        NOT NULL
        CHECK (partnership_type IN ('acquirer', 'issuer', 'correspondent')),
    contract_status   text        NOT NULL DEFAULT 'active'
        CHECK (contract_status IN ('active', 'suspended', 'terminated')),
    fee_share         numeric(5,4) NOT NULL DEFAULT 0 CHECK (fee_share >= 0 AND fee_share <= 1),
    since             date        NOT NULL DEFAULT CURRENT_DATE
);

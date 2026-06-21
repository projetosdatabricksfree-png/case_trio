-- =============================================================================
--  Sprint 01 · Story 1.1 — Tabela transacional: transactions (pré-hypertable)
--
--  Coração operacional da plataforma. Tipos do domínio financeiro:
--    - dinheiro   -> numeric(18,2) (nunca float)
--    - tempo      -> timestamptz
--    - flexível   -> jsonb (metadata)
--    - status/type-> text + CHECK (domínio pequeno e estável; evolui via ALTER
--                    barato, evitando o custo de ENUM nativo)
--
--  Chave primária: (id, created_at). O TimescaleDB exige que TODA constraint
--  única de uma hypertable inclua a coluna de particionamento (`created_at`).
--  Liderar por `id` mantém o lookup por id eficiente (prefixo do índice).
--  Trade-off documentado no REPORT (alternativa: sem PK + índice não-único).
--
--  `external_id` (idempotência de ingestão do pipeline da Sprint 05) recebe um
--  índice ÚNICO em 06_indexes.sql, aplicado PÓS-SEED para não pesar o COPY.
--
--  FKs nas colunas quentes (institution/account) são OMITIDAS de propósito:
--    (a) FK rígida em hypertable adiciona trigger por chunk e estrangula o COPY
--        de 10M linhas; (b) integridade é garantida pelo gerador do seed.
--    A abordagem de produção (FK NOT VALID + VALIDATE pós-carga) fica no REPORT.
-- =============================================================================

CREATE TABLE IF NOT EXISTS transactions (
    id                      uuid          NOT NULL DEFAULT gen_random_uuid(),
    external_id             uuid          NOT NULL DEFAULT gen_random_uuid(),
    amount                  numeric(18,2) NOT NULL CHECK (amount > 0),
    currency                char(3)       NOT NULL DEFAULT 'BRL',
    status                  text          NOT NULL
        CHECK (status IN ('pending', 'settled', 'failed', 'reversed')),
    type                    text          NOT NULL
        CHECK (type IN ('pix', 'ted', 'boleto', 'card')),
    source_institution      text          NOT NULL,   -- institution_code (soft-ref)
    destination_institution text          NOT NULL,   -- institution_code (soft-ref)
    source_account_id       uuid,
    destination_account_id  uuid,
    created_at              timestamptz   NOT NULL,
    settled_at              timestamptz,              -- NULL p/ pending/failed
    metadata                jsonb         NOT NULL DEFAULT '{}'::jsonb,
    PRIMARY KEY (id, created_at)
);

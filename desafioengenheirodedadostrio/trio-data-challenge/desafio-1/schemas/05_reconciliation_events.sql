-- =============================================================================
--  Sprint 01 · Story 1.1 / 1.5 — Tabela: reconciliation_events
--
--  Eventos de conciliação de transações com referências externas. Alimenta a Q2
--  da Sprint 02 (divergências de conciliação).
--
--  `transaction_id` é uma SOFT-REF para transactions: FK rígida apontando para uma
--  hypertable não é suportada pelo TimescaleDB. Guardamos também
--  `transaction_created_at` (cópia da partition key) para permitir JOIN
--  chunk-local com transactions; a integridade é garantida pelo gerador do seed.
--
--  `difference` é coluna GERADA (amount_received - amount_expected): mantém a
--  divergência sempre consistente, sem precisar calcular na aplicação.
-- =============================================================================

CREATE TABLE IF NOT EXISTS reconciliation_events (
    id                      uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    transaction_id          uuid          NOT NULL,
    transaction_created_at  timestamptz   NOT NULL,   -- partition key de transactions (join chunk-local)
    event_type              text          NOT NULL
        CHECK (event_type IN ('match', 'mismatch', 'missing', 'duplicate')),
    external_reference      text,
    amount_expected         numeric(18,2) NOT NULL,
    amount_received         numeric(18,2) NOT NULL,
    difference              numeric(18,2)
        GENERATED ALWAYS AS (amount_received - amount_expected) STORED,
    reconciled_at           timestamptz   NOT NULL DEFAULT now(),
    notes                   text
);

CREATE INDEX IF NOT EXISTS idx_recon_transaction
    ON reconciliation_events (transaction_id, transaction_created_at);

-- =============================================================================
--  Sprint 03 · Story 3.1 — Tabela de referência/configuração: institution_configs
--
--  O legado é um banco SEPARADO (trio_legado): não há FK cross-database para a
--  `institutions` do TimescaleDB. A referência é fisicamente DUPLICADA aqui, mas
--  GERADA da mesma SSOT (desafio-1/seed/institutions.py) — single source no nível
--  do gerador, sem divergência cross-banco.
--
--  DECISÃO A REGISTRAR: `institution_name` é a fonte que o dictionary
--  institution_code -> name do ClickHouse (Sprint 04) vai consumir. Tratar esta
--  tabela como um CONTRATO de referência versionado.
--
--  Domínios pequenos via CHECK (não ENUM); `settlement_window` (D+0/D+1/D+2) e
--  `fee_schedule` (jsonb) são parâmetros operacionais por instituição.
-- =============================================================================

CREATE TABLE IF NOT EXISTS institution_configs (
    institution_code  text PRIMARY KEY,            -- código no padrão ISPB (8 dígitos)
    institution_name  text        NOT NULL,
    short_name        text        NOT NULL,
    type              text        NOT NULL
        CHECK (type IN ('bank', 'fintech', 'payment_institution', 'credit_union')),
    settlement_window text        NOT NULL DEFAULT 'D+1'
        CHECK (settlement_window IN ('D+0', 'D+1', 'D+2')),
    fee_schedule      jsonb       NOT NULL DEFAULT '{}'::jsonb,
    api_endpoint      text,
    max_tx_per_day    integer     NOT NULL DEFAULT 1000000 CHECK (max_tx_per_day > 0),
    supports_pix      boolean     NOT NULL DEFAULT true,
    active            boolean     NOT NULL DEFAULT true,
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now()
);

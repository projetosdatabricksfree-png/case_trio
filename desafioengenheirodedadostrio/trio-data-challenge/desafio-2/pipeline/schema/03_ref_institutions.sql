-- =============================================================================
--  Sprint 05 · Story 5.4 — Cópia local da referência de instituições (PG -> CH)
--
--  Destino do pipeline secundário `sync_pg_refs`: full-refresh idempotente de
--  institution_configs (PostgreSQL legado) para uma tabela CONSULTÁVEL no
--  ClickHouse (~30 linhas). Espelha exatamente os campos que o dictionary da
--  Sprint 04 declara (institution_code -> name/short_name/type/settlement_window/
--  active), servindo como snapshot auditável e base p/ joins analíticos locais.
--
--  O dictionary `dict_institutions` (Sprint 04) SEGUE lendo o PG direto — Sprint
--  04 intacta. Este pipeline materializa a cópia e dispara SYSTEM RELOAD
--  DICTIONARY p/ o refresh imediato, sem esperar o LIFETIME.
--
--  ReplacingMergeTree(synced_at): cada refresh reescreve por institution_code; o
--  snapshot mais recente vence (o run faz TRUNCATE+INSERT, mas o engine garante
--  consistência mesmo sob inserts concorrentes).
-- =============================================================================

CREATE TABLE IF NOT EXISTS trio_analytics.ref_institutions
(
    institution_code  String,
    institution_name  String,
    short_name        String,
    type              LowCardinality(String),
    settlement_window LowCardinality(String),
    active            UInt8,
    synced_at         DateTime64(3, 'UTC') DEFAULT now64(3)
)
ENGINE = ReplacingMergeTree(synced_at)
ORDER BY institution_code;

-- =============================================================================
--  Sprint 04 · Story 4.1 — Tabela transacional analítica: transactions
--
--  ENGINE = ReplacingMergeTree(version)
--    Transações mudam de status (pending -> settled/failed/reversed). O ClickHouse
--    não faz UPDATE; o Replacing mantém a ÚLTIMA versão por chave de ordenação,
--    usando `version` (= updated_at) como desempate. Alternativas descartadas:
--      - MergeTree puro: sem dedup -> versões antigas vazariam nas leituras.
--      - AggregatingMergeTree: para MVs (estados), não para a base mutável.
--      - CollapsingMergeTree: exige sign +1/-1 e reenviar o estado anterior na
--        mutação -> mais frágil para um pipeline idempotente (Sprint 05).
--
--  ORDER BY (source_institution, type, created_at, id)  -- = chave de dedup
--    Todas as colunas são IMUTÁVEIS por transação (só status/settled_at/version
--    mudam). Logo a tupla é 1:1 com `id` e o Replacing colapsa exatamente as
--    versões da MESMA transação. `id` por último garante unicidade da chave.
--    A ordem (instituição, tipo, tempo) casa com os filtros mais comuns dos Data
--    Champions e com a query Pix/instituição/hora -> poda de granules eficiente.
--    Alternativa liderada por tempo discutida no REPORT.
--
--  PARTITION BY toYYYYMM(created_at)  -- mensal: poda forte de janelas recentes
--    sem explodir o nº de partes (diária geraria partes demais; anual poda fraca).
--
--  Codecs/tipos: Delta+ZSTD em timestamps (quase monotônicos); LowCardinality em
--  colunas de baixa cardinalidade (dicionário interno -> menos I/O, filtro rápido);
--  id/external_id gerados no servidor (DEFAULT) -> ficam fora do INSERT da carga.
-- =============================================================================

CREATE TABLE IF NOT EXISTS trio_analytics.transactions
(
    id                      UUID                             DEFAULT generateUUIDv4(),
    external_id             UUID                             DEFAULT generateUUIDv4(),
    amount                  Decimal(18, 2)                   CODEC(ZSTD(3)),
    currency                LowCardinality(String)           DEFAULT 'BRL',
    status                  LowCardinality(String),
    type                    LowCardinality(String),
    source_institution      LowCardinality(String),
    destination_institution LowCardinality(String),
    source_account_id       UUID,
    destination_account_id  UUID,
    created_at              DateTime64(3, 'UTC')             CODEC(Delta, ZSTD),
    settled_at              Nullable(DateTime64(3, 'UTC'))   CODEC(ZSTD),
    version                 DateTime64(3, 'UTC')             CODEC(Delta, ZSTD)
)
ENGINE = ReplacingMergeTree(version)
PARTITION BY toYYYYMM(created_at)
ORDER BY (source_institution, type, created_at, id)
SETTINGS index_granularity = 8192;

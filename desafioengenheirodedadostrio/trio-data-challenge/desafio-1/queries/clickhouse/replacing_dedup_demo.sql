-- =============================================================================
--  Sprint 04 · Story 4.6 — Prova determinística do dedup do ReplacingMergeTree
--
--  Demonstra a mutação de status (pending -> settled) SEM UPDATE, em tabela
--  descartável p/ NÃO sujar a carga principal (que fica exata para as MVs).
--  Dois INSERTs separados = duas partes (optimize_on_insert só colapsa DENTRO de
--  um bloco), então count() vê 2 "antes"; FINAL resolve a última versão por
--  `version`; OPTIMIZE FINAL faz o merge físico. Idempotente (DROP no início).
-- =============================================================================

DROP TABLE IF EXISTS trio_analytics.transactions_dedup_demo;

CREATE TABLE trio_analytics.transactions_dedup_demo
(
    id      UUID,
    status  LowCardinality(String),
    version DateTime64(3, 'UTC')
)
ENGINE = ReplacingMergeTree(version)
ORDER BY id;

INSERT INTO trio_analytics.transactions_dedup_demo VALUES
    ('11111111-1111-1111-1111-111111111111', 'pending', '2026-06-21 10:00:00.000');
INSERT INTO trio_analytics.transactions_dedup_demo VALUES
    ('11111111-1111-1111-1111-111111111111', 'settled', '2026-06-21 10:00:12.000');

SELECT 'antes (2 partes, sem merge)' AS fase,
       count() AS linhas
FROM trio_analytics.transactions_dedup_demo;

SELECT 'depois (FINAL: ultima versao)' AS fase,
       count()         AS linhas,
       any(status)     AS status_vencedor
FROM trio_analytics.transactions_dedup_demo FINAL;

OPTIMIZE TABLE trio_analytics.transactions_dedup_demo FINAL;

SELECT 'pos-OPTIMIZE (merge fisico)' AS fase,
       count()      AS linhas,
       any(status)  AS status_vencedor
FROM trio_analytics.transactions_dedup_demo;

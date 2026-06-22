-- =============================================================================
--  Sprint 02 · Índices das queries Q2 e Q4 (aplicados em make index-sprint02)
--
--  Separados dos índices da Sprint 01 (06_indexes.sql) porque nascem das queries
--  desta sprint. Cada um tem um "antes/depois" de EXPLAIN no REPORT.
-- =============================================================================

-- Q2 — índice PARCIAL: indexa SÓ as divergências de conciliação (~79k de 2M).
-- Chave = transaction_created_at (data da transação): a Q2 busca "transações
-- com divergência nos últimos 30 dias", então o range é sobre o tempo da
-- TRANSAÇÃO. Isso (a) torna o índice seletivo (~6k linhas recentes) e (b) como
-- transaction_created_at = transactions.created_at no join, propaga chunk
-- exclusion para a hypertable. O predicado replica o WHERE da Q2 (casa no
-- planner; abs() poderia não ser reconhecido). Resultado: Rows Removed by
-- Filter ~2M -> ~0 no lado da conciliação.
--
-- Nota de dado: o seed da Sprint 01 gravou reconciled_at = now() (uniforme),
-- então filtrar por reconciled_at não é seletivo; em produção reconciled_at
-- acompanha a transação. Usar transaction_created_at é a leitura realista.
CREATE INDEX IF NOT EXISTS idx_recon_divergent
    ON reconciliation_events (transaction_created_at DESC)
    WHERE difference > 0.01 OR difference < -0.01;

-- Q4 — índice composto p/ a window function. Ordem (amount, source_institution,
-- destination_institution, created_at): as 3 chaves de igualdade casam a
-- PARTITION BY e created_at fornece a ORDER BY → elimina o Sort do plano.
CREATE INDEX IF NOT EXISTS idx_tx_dedup
    ON transactions (amount, source_institution, destination_institution, created_at);

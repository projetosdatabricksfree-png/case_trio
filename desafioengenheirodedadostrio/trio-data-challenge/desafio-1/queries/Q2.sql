-- =============================================================================
--  Sprint 02 · Q2 — Divergências de conciliação (últimos 30 dias) + contas
--
--  Divergência = |amount_received - amount_expected| > R$0,01. `difference` é
--  coluna GERADA STORED (não recalcula em runtime).
--
--  Janela = data da TRANSAÇÃO (transaction_created_at): "transações com
--  divergência nos últimos 30 dias". (O seed gravou reconciled_at uniforme =
--  now(), então filtrar por reconciled_at não seria seletivo; em produção
--  reconciled_at acompanha a transação. Ver nota no 07_indexes_sprint02.sql.)
--
--  TRÊS alavancas de otimização (todas necessárias — ver REPORT p/ planos):
--   1. Índice PARCIAL idx_recon_divergent (transaction_created_at) WHERE
--      divergente: ~79k divergências de 2M; o range de 30 dias as corta a ~6k.
--   2. CTE `MATERIALIZED`: barreira de otimização que FORÇA o uso do índice
--      parcial. Sem ela o planner subestima a seletividade do predicado OR sobre
--      a coluna GERADA `difference` (estima rows=1) e cai num hash join que
--      varre os 10M — adicionar só o índice NÃO basta.
--   3. Bound redundante `t.created_at >= now()-30d` (idêntico via a igualdade do
--      join): restaura a CHUNK EXCLUSION no lado transactions (Merge Append em
--      ~30 chunks), em vez de varrer a hypertable inteira.
--  Resultado: ~6,1 s (ingênuo, seq scan dos 10M) -> ~1,3 s.
-- =============================================================================

WITH divergencias AS MATERIALIZED (
    SELECT transaction_id, transaction_created_at, event_type,
           amount_expected, amount_received, difference, reconciled_at
    FROM reconciliation_events
    WHERE transaction_created_at >= now() - INTERVAL '30 days'
      AND (difference > 0.01 OR difference < -0.01)
)
SELECT d.transaction_id,
       d.reconciled_at,
       d.event_type,
       t.amount,
       t.type,
       d.amount_expected,
       d.amount_received,
       d.difference,
       sa.holder_name      AS source_holder,
       da.holder_name      AS destination_holder,
       si.short_name       AS source_institution,
       di.short_name       AS destination_institution
FROM divergencias d
JOIN transactions t
      ON t.id         = d.transaction_id
     AND t.created_at = d.transaction_created_at
LEFT JOIN accounts     sa ON sa.id = t.source_account_id
LEFT JOIN accounts     da ON da.id = t.destination_account_id
LEFT JOIN institutions si ON si.institution_code = t.source_institution
LEFT JOIN institutions di ON di.institution_code = t.destination_institution
WHERE t.created_at >= now() - INTERVAL '30 days'   -- redundante via join: força chunk exclusion
ORDER BY abs(d.difference) DESC
LIMIT 100;

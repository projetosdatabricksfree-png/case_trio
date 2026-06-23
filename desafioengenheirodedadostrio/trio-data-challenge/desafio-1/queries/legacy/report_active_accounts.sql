-- =============================================================================
--  Sprint 03 · Story 3.2 — Relatório de contas ATIVAS por instituição
--
--  Agregações por (instituição, tipo de conta): nº de contas ativas, saldo total
--  e médio. Junta institution_configs só para trazer o nome.
--
--  ÍNDICE: idx_accounts_active_cover — parcial (status='active') + cobertura
--  (INCLUDE balance) em (institution_code, account_type).
--
--  EXPLAIN (resumo; detalhe no REPORT):
--    - RELATÓRIO COMPLETO (todas as instituições): o planner MANTÉM Seq Scan +
--      HashAggregate mesmo com o índice. Correto — `status='active'` não é
--      seletivo (93% das contas) e a relação é pequena (~488 páginas): varrer o
--      índice custaria páginas equivalentes com I/O aleatório. Não indexar por
--      reflexo é decisão sênior; o índice serve o caminho de acesso SELETIVO.
--    - DRILL-DOWN (1 instituição): aí o índice PAGA — vira Index Only Scan
--      (Heap Fetches 0), buffers ~488 -> ~25, tempo ~33ms -> ~1ms. Reprodução do
--      drill-down documentada no REPORT.
-- =============================================================================

SELECT a.institution_code,
       ic.institution_name,
       a.account_type,
       count(*)                  AS active_accounts,
       round(sum(a.balance), 2)  AS total_balance,
       round(avg(a.balance), 2)  AS avg_balance
FROM accounts a
JOIN institution_configs ic ON ic.institution_code = a.institution_code
WHERE a.status = 'active'
GROUP BY a.institution_code, ic.institution_name, a.account_type
ORDER BY a.institution_code, a.account_type;

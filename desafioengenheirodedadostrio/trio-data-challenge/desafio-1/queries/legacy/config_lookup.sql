-- =============================================================================
--  Sprint 03 · Story 3.3 — Lookup operacional com join de 5 tabelas
--
--  "Contas ativas acima do limite diário, em instituições ATIVAS que liquidam em
--   D+1, com seu adquirente (acquirer) ativo." Join:
--     institution_configs ⋈ accounts ⋈ users ⋈ account_limits ⋈ institution_partners
--
--  ÍNDICES (FKs que o Postgres NÃO cria sozinho): idx_accounts_institution,
--  idx_accounts_user, idx_partners_institution.
--
--  EXPLAIN (resumo; detalhe no REPORT):
--    - ANTES: 4 Hash Joins encadeados + Seq Scan em accounts (36k filtradas) —
--      ~1.216 buffers, ~23ms. Plano já razoável porque tudo cabe em cache.
--    - DEPOIS: com idx_accounts_institution o planner PIVOTA para Nested Loop
--      dirigido pelas 12 instituições D+1, com Bitmap Index Scan em accounts. Em
--      39k linhas (cache-resident) o ganho é de PLANO/escala, não de buffers
--      brutos — daí a leitura honesta no REPORT.
--    - DRILL-DOWN (1 instituição): o índice cobra: Bitmap Index Scan lê só as
--      contas daquela instituição (~467 páginas) em vez de varrer 39k. Reprodução
--      no REPORT.
--
--  Filtro acquirer (1 parceiro por instituição) evita multiplicar linhas por
--  parceria — o lookup retorna a conta com seu adquirente principal.
-- =============================================================================

SELECT u.id          AS user_id,
       u.full_name,
       a.id          AS account_id,
       a.balance,
       ic.institution_code,
       ic.institution_name,
       ic.settlement_window,
       al.daily_limit,
       p.partner_name
FROM institution_configs ic
JOIN accounts a             ON a.institution_code = ic.institution_code
JOIN users u                ON u.id = a.user_id
JOIN account_limits al      ON al.account_id = a.id
JOIN institution_partners p ON p.institution_code = ic.institution_code
WHERE ic.active
  AND ic.settlement_window = 'D+1'
  AND a.status = 'active'
  AND a.balance > al.daily_limit
  AND p.contract_status = 'active'
  AND p.partnership_type = 'acquirer'
ORDER BY a.balance DESC
LIMIT 100;

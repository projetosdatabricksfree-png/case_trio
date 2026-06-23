-- =============================================================================
--  Sprint 03 · Story 3.1 — Índices de apoio do legado (aplicados PÓS-SEED)
--
--  Separados do schema base (make index-legado) para que o EXPLAIN "antes" das
--  Stories 3.2/3.3 mostre o cenário SEM índice (Seq Scan / join por hash sem FK
--  indexada) e o "depois" evidencie o ganho. O Postgres NÃO cria índice de FK
--  automaticamente — daí o gargalo nas FKs cruas de accounts/partners.
-- =============================================================================

-- Q3.2 — relatório de contas ATIVAS por instituição. Índice PARCIAL (só ativas,
-- ~95% mas evita as bloqueadas/fechadas) + COBERTURA (INCLUDE balance): a query
-- agrega count/sum/avg(balance) agrupando por (institution_code, account_type),
-- então todas as colunas saem do índice -> Index Only Scan (Heap Fetches ~0).
CREATE INDEX IF NOT EXISTS idx_accounts_active_cover
    ON accounts (institution_code, account_type)
    INCLUDE (balance)
    WHERE status = 'active';

-- Q3.3 — join dirigido pelo filtro em institution_configs (active, D+1). Indexar
-- a FK accounts.institution_code permite ir das ~poucas instituições filtradas
-- direto às suas contas (Index Scan) em vez de varrer accounts inteira.
CREATE INDEX IF NOT EXISTS idx_accounts_institution
    ON accounts (institution_code);

-- FK accounts.user_id: habilita o join accounts<->users também na direção
-- dirigida por users e evita Seq Scan quando o planner inverte a ordem.
CREATE INDEX IF NOT EXISTS idx_accounts_user
    ON accounts (user_id);

-- FK institution_partners.institution_code: join partners<->configs indexado.
CREATE INDEX IF NOT EXISTS idx_partners_institution
    ON institution_partners (institution_code);

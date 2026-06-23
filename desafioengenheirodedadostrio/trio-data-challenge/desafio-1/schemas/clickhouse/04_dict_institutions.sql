-- =============================================================================
--  Sprint 04 · Story 4.3 — Dictionary institution_code -> institution_name
--
--  Fonte = institution_configs do POSTGRES LEGADO (trio_legado), populado na
--  Sprint 03. Fecha o gancho arquitetural: a referência de instituições tem UMA
--  origem (SSOT institutions.py -> legado) e o ClickHouse a consome via dictionary
--  em memória. O pipeline de referência da Sprint 05 mantém isso atualizado;
--  LIFETIME faz o refresh automático.
--
--  dictionary > JOIN aqui: lookup de baixa cardinalidade (~30 linhas) carregado
--  em memória é O(1) por chave e evita hash join; ideal para dados de referência
--  que mudam pouco. JOIN só compensa para tabelas grandes/voláteis.
--
--  Segredo: a senha NÃO é commitada. O arquivo usa o placeholder __PG_PASSWORD__
--  e `make migrate-ch` injeta POSTGRES_PASSWORD do .env via sed no momento do
--  apply. Chave String -> layout complex_key_hashed.
-- =============================================================================

CREATE DICTIONARY IF NOT EXISTS trio_analytics.dict_institutions
(
    institution_code  String,
    institution_name  String,
    short_name        String,
    type              String,
    settlement_window String,
    active            UInt8
)
PRIMARY KEY institution_code
SOURCE(POSTGRESQL(
    host 'postgres-legado'
    port 5432
    user 'trio'
    password '__PG_PASSWORD__'
    db 'trio_legado'
    table 'institution_configs'
))
LAYOUT(COMPLEX_KEY_HASHED())
LIFETIME(MIN 300 MAX 600);

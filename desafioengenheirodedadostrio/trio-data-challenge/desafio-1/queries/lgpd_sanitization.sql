-- =============================================================================
--  Sprint 02 · Story 2.6 — Sanitização LGPD (direito ao esquecimento)
--
--  PROBLEMA CENTRAL: chunks comprimidos são imutáveis em nível de linha — não se
--  faz UPDATE/DELETE pontual sem DESCOMPRIMIR o chunk antes.
--
--  -------------------------------------------------------------------------
--  ARQUITETURA RECOMENDADA (mitigação primária) — PII vault / surrogate key
--  -------------------------------------------------------------------------
--  Na nossa modelagem a PII (holder_document, holder_name) vive em `accounts`,
--  uma tabela-dimensão pequena e NÃO comprimida; a hypertable `transactions` só
--  carrega o UUID substituto (source/destination_account_id). Consequência: o
--  esquecimento é um UPDATE/DELETE indexado por id em `accounts` — O(1), sem
--  tocar nos 10M nem descomprimir nada. Política: PROIBIR PII em
--  transactions.metadata (gancho RF-1.8). Esta é a forma barata e correta.
--
--  Demonstração do caminho vault (não-destrutiva — roda em transação revertida):
BEGIN;
UPDATE accounts
   SET holder_name     = '[ANONIMIZADO-LGPD]',
       holder_document = '[ANONIMIZADO-LGPD]'
 WHERE id = (SELECT id FROM accounts ORDER BY id LIMIT 1);
SELECT id, holder_name, holder_document FROM accounts ORDER BY id LIMIT 1;  -- mascarado
ROLLBACK;  -- demo: desfaz; em produção seria COMMIT + trilha de auditoria

--  -------------------------------------------------------------------------
--  RUNBOOK (fallback) — PII que JÁ está num chunk comprimido (ex.: metadata)
--  -------------------------------------------------------------------------
--  Sempre ESCOPADO ao(s) chunk(s) do titular (nunca a hypertable inteira),
--  em janela de manutenção, verificando storage livre (a descompressão infla o
--  chunk ~5-20x; coexistem cópia comprimida + descomprimida ~2x).
--
--    1. Identificar os chunks pelo range temporal da atividade do titular:
--         SELECT show_chunks('transactions',
--                            newer_than => '<inicio>', older_than => '<fim>');
--    2. Descomprimir cada chunk-alvo:
--         SELECT decompress_chunk('<chunk>');
--    3. Mascarar/Excluir a PII (UPDATE anonimiza; DELETE remove):
--         UPDATE transactions SET metadata = metadata - 'cpf' - 'holder_name'
--          WHERE <predicado do titular> AND created_at <@ '<range do chunk>';
--    4. Recomprimir explicitamente (não esperar a policy → limita a janela
--       descomprimida):
--         SELECT compress_chunk('<chunk>');
--    5. Validar contagem antes/depois e registrar trilha de auditoria.
--
--  Preferir SANITIZAÇÃO EM LOTE (acumular solicitações) para descomprimir cada
--  chunk uma única vez. Se um DELETE alterar agregados, refrescar os CAggs do
--  range (invalidação). Mascarar só coluna de texto não afeta os agregados
--  (amount/status/type/created_at), então os CAggs ficam intactos.
--
--  TimescaleDB 2.x suporta DML direto em chunk comprimido (descompressão
--  implícita só dos batches afetados); ainda assim, scrubs amplos pedem o
--  runbook explícito acima para controlar I/O, locks e storage.
-- =============================================================================

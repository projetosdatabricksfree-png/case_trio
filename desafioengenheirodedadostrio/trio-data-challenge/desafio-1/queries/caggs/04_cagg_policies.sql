-- =============================================================================
--  Sprint 02 · Story 2.1 — Refresh policies dos CAggs (atualização automática)
--
--  SEM policy o CAgg NÃO se atualiza sozinho (falha silenciosa clássica). A
--  policy refaz a janela [now()-start_offset, now()-end_offset] a cada execução,
--  processando o log de invalidação só dentro dela.
--
--  end_offset = zona de quarentena junto ao now(): buckets recentes ainda
--    recebem escrita (micro-batch da Sprint 05); não materializar o bucket
--    corrente evita churn.
--  start_offset = janela de auto-correção: precisa DOMINAR o atraso máximo do
--    dado, senão um dado tardio mais antigo que start_offset é registrado na
--    invalidação mas nunca reprocessado pela policy automática.
--
--  CAgg A (1h): start_offset 3 dias cobre atraso de ingestão; end_offset 1h.
--  CAgg B (1d): start_offset 7 dias DOMINA a cauda de liquidação (uma transação
--    criada hoje pode liquidar como 'settled' depois — UPDATE de status num
--    bucket de created_at já passado gera invalidação; 7d dá folga sobre o
--    boleto ~12h); end_offset 1 dia (1 bucket de quarentena).
-- =============================================================================

SELECT add_continuous_aggregate_policy('cagg_volume_by_type_hourly',
    start_offset      => INTERVAL '3 days',
    end_offset        => INTERVAL '1 hour',
    schedule_interval => INTERVAL '1 hour',
    if_not_exists     => TRUE);

SELECT add_continuous_aggregate_policy('cagg_settlement_by_institution_daily',
    start_offset      => INTERVAL '7 days',
    end_offset        => INTERVAL '1 day',
    schedule_interval => INTERVAL '1 hour',
    if_not_exists     => TRUE);

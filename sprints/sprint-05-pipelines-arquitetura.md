# Sprint 05 — Pipelines & Arquitetura

> **Dias:** 4–5 · **Peso:** Arquitetura e Visão (25%) · **Stories:** 6
> **Cobre:** RF-4.1 a RF-4.6 · **Desafio 2 (Partes A, B, C)**
> **Objetivo:** Pipeline principal TimescaleDB → ClickHouse idempotente e observável, tratamento de mutações, pipeline secundário de referência, diagrama arquitetural completo e ADR defensável.

---

## Contexto

O pipeline é o requisito de aceitação mais crítico do Desafio 2: *"Pelo menos um pipeline (TimescaleDB → ClickHouse) funciona end-to-end de forma demonstrável"*. A escolha de abordagem (micro-batch vs CDC) precisa ser **justificada por escrito**. O ADR e o diagrama carregam a maior parte da nota de Arquitetura (25%) e alimentam várias perguntas da apresentação.

**Depende de:** Sprint 01 (origem TimescaleDB), Sprint 03 (origem de referência), Sprint 04 (destino ClickHouse).
**Habilita:** Sprint 06 (dashboard de pipeline observa estas métricas).

---

## Definition of Done da Sprint

- [ ] Pipeline TimescaleDB → ClickHouse roda end-to-end no compose, idempotente.
- [ ] Falhas tratadas (retry, dead-letter, logging estruturado); lag/throughput observáveis.
- [ ] Mutação de status (pending → settled) refletida corretamente no ClickHouse, demonstrada.
- [ ] Pipeline secundário PostgreSQL → ClickHouse alimentando os dictionaries.
- [ ] Diagrama arquitetural completo (origem → consumo) com componentes AWS e SLAs.
- [ ] ADR de 1–2 páginas com trade-offs, plano de escala 10x e visão cloud-native.

---

## Story 5.1 — Desenho do pipeline e decisão de abordagem

**Descrição:** Decidir e justificar a abordagem do pipeline principal antes de implementar. **(Plan Mode obrigatório; considerar Opus para a justificativa.)**

**Tarefas:**
- Avaliar as opções do desafio e registrar a decisão:
  - **CDC (Debezium/Kafka):** fiel a produção, mas pesado/instável em docker local; risco de não ser demonstrável em 7 dias.
  - **Replicação lógica nativa** (TimescaleDB é PostgreSQL): elegante, porém complexa de orquestrar e com nuances em chunks comprimidos.
  - **Pipeline custom (Python micro-batch):** ✅ **escolhido** — idempotente, simples, 100% demonstrável no compose.
  - Outra abordagem.
- **Justificativa escrita:** por que micro-batch e não os outros; quais trade-offs (latência de minutos vs segundos; simplicidade vs fidelidade a produção). Deixar claro que **em produção AWS** a evolução natural é CDC com Debezium + MSK/Kafka.
- Definir o mecanismo de **idempotência:** watermark (`last_processed_updated_at`/`max(created_at)`) persistido (em tabela de controle no ClickHouse ou no próprio TimescaleDB) + dedup via `ReplacingMergeTree(version)`.
- Definir o contrato de dados (colunas mapeadas TS → CH, tipos).

**Critério de aceitação:** decisão registrada com trade-offs; estratégia de idempotência e watermark definida.

**Artefatos:** rascunho do `desafio-2/ADR.md` (decisão do pipeline) — consolidado na Story 5.6.

---

## Story 5.2 — Pipeline principal TimescaleDB → ClickHouse

**Descrição:** Implementar o pipeline micro-batch idempotente e observável.

**Tarefas:**
- Script Python (`desafio-2/pipeline/sync_ts_to_ch.py`) que:
  - Lê do TimescaleDB transações novas/alteradas desde o watermark (`WHERE updated_at > :watermark` — pressupõe coluna `updated_at` na origem; adicionar se necessário na Sprint 01).
  - Transforma para o schema ClickHouse (incluindo a coluna `version` para o ReplacingMergeTree).
  - Insere em micro-batches no ClickHouse (`clickhouse-connect`, `INSERT` em lote).
  - Atualiza o watermark **após** confirmação do batch (commit do progresso).
- **Idempotência:** re-execução não duplica — garantido por watermark + dedup do ReplacingMergeTree. Demonstrar rodando o pipeline duas vezes e comparando contagem (com `FINAL`).
- **Observabilidade mínima:**
  - Logs estruturados (JSON): batch size, rows lidas/inseridas, lag (now − max(created_at) processado), duração, erros.
  - Expor métricas (contadores em log ou endpoint `/metrics` simples) para o dashboard de pipeline (Sprint 06).
- **Resiliência:**
  - Retry com backoff exponencial em falhas transitórias.
  - Dead-letter: rows que falham repetidamente vão para uma área/tabela de DLQ com motivo.
  - Logging de cada falha com contexto.
- Modo de execução: loop contínuo (poll a cada N segundos) e/ou cronjob — demonstrável no compose como serviço.

**Critério de aceitação:** `docker compose up` sobe o pipeline; transações fluem TS → CH; rodar 2x não duplica; logs mostram lag/throughput; falha simulada aciona retry/DLQ.

**Artefatos:** `desafio-2/pipeline/sync_ts_to_ch.py`, tabela de controle de watermark, entrada no compose.

---

## Story 5.3 — Tratamento de mutações (status pending → settled)

**Descrição:** Garantir que mudanças de status na origem se reflitam corretamente no ClickHouse.

**Tarefas:**
- Demonstrar o ciclo: inserir transação `pending` → pipeline sincroniza → atualizar para `settled` na origem (com `updated_at` novo) → pipeline re-sincroniza → ClickHouse reflete `settled`.
- O `ReplacingMergeTree(version)` mantém a versão de maior `version`; leitura com `FINAL` (ou `argMax(..., version)`) retorna o estado atual.
- Discutir o trade-off de consistência: entre o `UPDATE` na origem e o `OPTIMIZE`/merge no ClickHouse, leituras sem `FINAL` podem ver a versão antiga — explicar como mitigar (FINAL na query crítica, ou `OPTIMIZE ... FINAL` agendado, ou design da MV que já resolve por `argMax`).
- Validar com contagem/estado antes e depois da mutação.

**Critério de aceitação:** mutação de status demonstrada end-to-end; ClickHouse reflete o estado correto; trade-off documentado.

**Artefatos:** script/demo de mutação, seção no ADR/REPORT.

---

## Story 5.4 — Pipeline secundário PostgreSQL → ClickHouse (dictionaries)

**Descrição:** Sincronizar dados de referência do legado para alimentar os dictionaries.

**Tarefas:**
- Pipeline (`desafio-2/pipeline/sync_pg_refs.py`) que sincroniza instituições/contas/configs do PostgreSQL legado para o ClickHouse (tabela de referência ou direto para a fonte do dictionary).
- **Frequência e consistência:** dados de referência mudam pouco — sincronização periódica (ex: a cada hora) é suficiente; justificar. Garantir consistência (full refresh idempotente para tabelas pequenas, ou upsert).
- Após sync, garantir que o dictionary do ClickHouse recarrega (via `LIFETIME` ou `SYSTEM RELOAD DICTIONARY`).
- **Resiliência a migração:** descrever como esse pipeline se comporta sob migração PostgreSQL → Aurora:
  - O que muda: apenas o **endpoint/connection string** (Aurora é wire-compatible com PostgreSQL).
  - O que precisa adaptar: credenciais/IAM auth, possíveis ajustes de SSL, endpoint de cluster (writer/reader).
  - **O pipeline sobrevive sem mudanças de lógica** — só configuração. Esse é um argumento forte de design (desacoplar via connection string/env).

**Critério de aceitação:** referência flui PG → CH; dictionary reflete atualizações; análise de sobrevivência à migração escrita.

**Artefatos:** `desafio-2/pipeline/sync_pg_refs.py`, seção no ADR.

---

## Story 5.5 — Diagrama arquitetural completo

**Descrição:** Diagrama do fluxo completo de dados, da origem ao consumo, com componentes AWS e SLAs.

**Tarefas:**
- Diagrama (Mermaid no markdown e/ou export de draw.io como PNG em `desafio-2/diagrams/`) incluindo:
  - **Todos os componentes:** TimescaleDB (Timescale Cloud), PostgreSQL/Aurora (legado), ClickHouse, pipelines (principal e referência), filas/DLQ se houver, Grafana, Hex, API e aplicações consumidoras.
  - **Serviços AWS:** VPC + subnets, S3 (backups + lifecycle), CloudWatch + SNS, IAM, MSK/Kafka (CDC futuro), DMS (migração).
  - **Direção dos fluxos** e **SLAs esperados** (latência por hop, freshness alvo — ex: pipeline ≤ X min, query Grafana sub-segundo).
  - **Pontos de falha** e estratégias de mitigação anotados no diagrama.

**Critério de aceitação:** diagrama legível, completo, com AWS e SLAs; pontos de falha marcados.

**Artefatos:** `desafio-2/diagrams/architecture.md` (Mermaid) e/ou `architecture.png`.

---

## Story 5.6 — Architecture Decision Record (ADR)

**Descrição:** ADR de 1–2 páginas consolidando e justificando as escolhas. **(Considerar Opus.)**

**Tarefas — responder obrigatoriamente:**
- **Por que não um ETL tradicional?** (batch noturno vs micro-batch/CDC; freshness exigida pelos Data Champions e aplicações).
- **Como escalar se o volume 10x?**
  - Pipeline: migrar micro-batch → CDC (Debezium + MSK/Kafka) para throughput e latência; particionar por instituição/tópico.
  - ClickHouse: sharding + replicação (`ReplicatedMergeTree`), distribuição de partições.
  - TimescaleDB: ajustar chunk interval, mais compressão, read replicas.
- **Onde entra o legado PostgreSQL/Aurora nessa evolução?** (referência desacoplada via connection string; migração não quebra pipeline).
- **Quais serviços AWS para resiliência e escala?** MSK, S3, CloudWatch/SNS, IAM, Aurora (Global Database p/ DR), Auto Scaling, etc.
- Formato ADR: Contexto · Decisão · Alternativas consideradas · Consequências (positivas/negativas) · Trade-offs.

**Critério de aceitação:** ADR de 1–2 páginas, estruturado, respondendo às quatro perguntas-âncora com profundidade.

**Artefatos:** `desafio-2/ADR.md`.

---

## Riscos da Sprint

| Risco | Mitigação |
|---|---|
| Pipeline não idempotente (duplica) | Watermark + ReplacingMergeTree; testar rodando 2x |
| Falta coluna `updated_at` na origem | Adicionar na Sprint 01 ou usar trigger; pré-requisito da Story 5.2 |
| Mutação não reflete (lê versão antiga) | `FINAL`/`argMax`; explicar trade-off de consistência |
| ADR genérico | Responder às 4 perguntas-âncora com números e serviços concretos |
| Diagrama sem AWS/SLAs | Checklist da Story 5.5 |

---

## Saída para a próxima sprint

Com dados fluindo e arquitetura documentada, a Sprint 06 adiciona a camada operacional (backup, recovery, observabilidade) — incluindo o dashboard que observa as métricas deste pipeline. `/compact` preservando: abordagem do pipeline, mecanismo de watermark, tratamento de mutação, e as decisões do ADR (citadas extensivamente na apresentação).

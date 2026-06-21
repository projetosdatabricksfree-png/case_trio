# Sprint 01 — TimescaleDB: Modelagem & Dados

> **Dias:** 1–2 · **Peso:** Profundidade Técnica (40%) · **Stories:** 5
> **Cobre:** RF-1.1, RF-1.2, RF-1.3 · **Desafio 1 / Parte A** (tarefas 1–3)
> **Objetivo:** Schema transacional modelado, `transactions` como hypertable bem justificada, e seed realista de 10M+ transações em 12 meses gerado em janela aceitável.

---

## Contexto

Esta sprint cria o **coração operacional** da plataforma. A qualidade da modelagem e a justificativa das escolhas de hypertable valem pontos diretos na nota técnica (40%). O seed precisa ser **eficiente** — `INSERT` linha a linha de 10M rows inviabiliza todo o resto do desafio.

**Depende de:** Sprint 00 (TimescaleDB saudável).
**Habilita:** Sprint 02 (CAggs/queries), Sprint 05 (pipeline lê daqui).

---

## Definition of Done da Sprint

- [x] Schema `transactions`, `accounts`, `reconciliation_events` criado via migration idempotente.
- [x] `transactions` é hypertable com chunk interval definido e **justificado por escrito**.
- [x] 10M+ transações geradas em 12 meses, com distribuição realista validada por queries de sanidade.
- [x] Seed roda em janela aceitável (< 15 min como alvo) via `COPY`/batch.
- [x] `accounts` e `reconciliation_events` populados de forma coerente (FKs/relacionamentos plausíveis).
- [x] Documentação inicial da modelagem em `desafio-1/REPORT.md`.

---

## Story 1.1 — Schema transacional base

**Descrição:** Criar as três tabelas com tipos corretos e constraints, prontas para virar hypertable.

**Tarefas:**
- `transactions`:
  - `id` UUID (o escopo §3 Parte A especifica `id (UUID)`); opcionalmente um `external_id` UUID adicional para idempotência de ingestão/pipeline — adição **deliberada** amparada pelo "adapte conforme julgar necessário" do enunciado, não um desvio. `amount` numeric(18,2), `currency` (text/char), `status` enum-like (`pending`/`settled`/`failed`/`reversed`), `type` (`pix`/`ted`/`boleto`/`card`), `source_institution`, `destination_institution`, `created_at` timestamptz, `settled_at` timestamptz null, `metadata` jsonb.
- `accounts`: `id`, `account_number`, `institution_code`, `holder_document` (cpf/cnpj), `holder_name`, `account_type`, `status`, `created_at`.
- `reconciliation_events`: `id`, `transaction_id`, `event_type`, `external_reference`, `amount_expected`, `amount_received`, `difference` (gerada ou calculada), `reconciled_at`, `notes`.
- Usar `CHECK` constraints para `status`/`type` ou tipos ENUM nativos (decidir; ENUM tem implicações em alteração futura — comentar).
- Migration idempotente (`CREATE TABLE IF NOT EXISTS`), arquivada em `desafio-1/schemas/`.

**Critério de aceitação:** tabelas criadas; tipos refletem domínio financeiro (numeric para dinheiro, timestamptz para tempo, jsonb para metadata flexível).

**Decisão a registrar:** chave primária da hypertable precisa **incluir a coluna de particionamento** (`created_at`) se houver PK — TimescaleDB exige isso. Documentar o trade-off (PK composta vs unique index).

**Artefatos:** `desafio-1/schemas/01_transactions.sql`, `02_accounts.sql`, `03_reconciliation_events.sql`.

---

## Story 1.2 — Converter `transactions` em hypertable

**Descrição:** Transformar `transactions` em hypertable e justificar chunk interval e dimensão de particionamento.

**Tarefas:**
- `SELECT create_hypertable('transactions', by_range('created_at', INTERVAL '1 day'));`
- Avaliar **space partitioning** adicional (ex: por `type` ou hash de `source_institution`) — decidir e justificar (geralmente desnecessário neste volume; documentar por quê).
- Definir e justificar `chunk_time_interval`:
  - Padrão de consulta concentra nos últimos 30–90 dias.
  - Compressão de chunks 7+ dias e retenção de 90 dias pedem granularidade.
  - **1 dia** dá ~365 chunks/ano — equilíbrio entre exclusão de chunk no planner e overhead de muitos chunks. Comentar a regra geral (chunk deve caber confortavelmente em memória; 25% da RAM como referência).

**Critério de aceitação:** `transactions` é hypertable; `SELECT * FROM timescaledb_information.dimensions` confirma a dimensão; justificativa do interval escrita no REPORT.

**Atenção:** criar a hypertable **antes** do seed massivo (converter tabela já cheia é mais custoso).

**Artefatos:** `desafio-1/schemas/04_hypertable.sql`, seção no `REPORT.md`.

---

## Story 1.3 — Gerador de dados: design e instituições/contas

**Descrição:** Construir o gerador Python e popular as dimensões (`accounts` e o universo de instituições) que dão coerência ao seed transacional.

**Tarefas:**
- Script Python (`desafio-1/seed/`) com:
  - Lista fixa de ~20–50 instituições (código + nome) reutilizada por `transactions`, `accounts` e (depois) pelo dictionary do ClickHouse.
  - Geração de `accounts` (algumas dezenas de milhares) com documentos válidos no formato (CPF/CNPJ — gerar com dígito verificador plausível via `Faker pt_BR`).
  - Configuração centralizada: total de transações, janela temporal (12 meses), seed do RNG para reprodutibilidade.
- Usar `Faker(locale='pt_BR')` + `numpy` para distribuições.

**Critério de aceitação:** `accounts` populado; lista de instituições persistida (em tabela ou arquivo) para reuso cross-banco.

**Decisão a registrar:** a mesma lista de instituições alimentará o dictionary do ClickHouse (Sprint 04) — garantir fonte única de verdade.

**Artefatos:** `desafio-1/seed/generators.py`, `desafio-1/seed/institutions.py` (ou tabela seed).

---

## Story 1.4 — Seed de 10M+ transações com distribuição realista

**Descrição:** Gerar e carregar 10M+ transações com distribuição estatisticamente realista, de forma performática.

**Tarefas:**
- **Distribuição realista:**
  - Mix por tipo: Pix >> TED > cartão > boleto (ex: ~70% Pix, 15% cartão, 10% TED, 5% boleto — justificar).
  - Picos em **dias úteis** e horário comercial; vales em fins de semana/madrugada (modular probabilidade por dia-da-semana e hora).
  - Variação de `status`: maioria `settled`, fração `pending`/`failed`/`reversed` (ex: 90/5/3/2).
  - `settled_at` coerente: null para `pending`/`failed`; para `settled`, `created_at` + latência realista (Pix segundos; boleto/TED minutos a horas).
  - `amount` com distribuição log-normal (muitas transações pequenas, cauda de grandes).
  - Múltiplas instituições de origem/destino a partir do universo da Story 1.3.
- **Performance — escolher e justificar:**
  - **`COPY FROM`** com CSV/stream gerado em chunks (recomendado) — ordem de magnitude mais rápido que INSERT.
  - Alternativa: `execute_values` em batches de 10–50k com `autocommit` controlado.
  - Considerar desabilitar índices secundários durante o load e recriá-los depois.
- Gerar em lotes (ex: 500k por vez) para não estourar memória.

**Critério de aceitação:**
- `SELECT count(*) FROM transactions` ≥ 10.000.000.
- Seed completa em janela aceitável (cronometrar; alvo < 15 min).
- Queries de sanidade confirmam distribuição (ver Story 1.5).

**Atenção:**
- Carregar dados já **ordenados por `created_at`** melhora compressão e localidade de chunk.
- Rodar `ANALYZE transactions;` ao final para estatísticas do planner (crítico para a Sprint 02).

**Artefatos:** `desafio-1/seed/seed_transactions.py`.

---

## Story 1.5 — Reconciliação, validação e REPORT inicial

**Descrição:** Popular `reconciliation_events` de forma coerente, validar o seed com queries de sanidade e documentar a modelagem.

**Tarefas:**
- Gerar `reconciliation_events` para um subconjunto de transações:
  - Maioria com `amount_expected == amount_received` (diferença 0).
  - Fração com divergência > R$0,01 (alimenta a Q2 da Sprint 02) — garantir que existem casos para a query encontrar.
- **Queries de sanidade** (salvar em `desafio-1/queries/sanity/`):
  - Contagem total e por tipo (validar mix).
  - Distribuição de status.
  - Volume por dia-da-semana (validar picos em dias úteis).
  - Min/max/avg de `amount`.
  - Latência média de liquidação por tipo.
  - Contagem de divergências de reconciliação.
- `desafio-1/REPORT.md` (seção de modelagem): decisões de schema, justificativa do chunk interval, estratégia e performance do seed, evidências da distribuição (saída das queries de sanidade).

**Critério de aceitação:** distribuição validada e documentada; `reconciliation_events` tem casos divergentes; REPORT inicial escrito.

**Artefatos:** `desafio-1/seed/seed_reconciliation.py`, `desafio-1/queries/sanity/*.sql`, `desafio-1/REPORT.md`.

---

## Riscos da Sprint

| Risco | Mitigação |
|---|---|
| Seed lento inviabiliza o resto | `COPY FROM`; validar tempo já na Story 1.4 |
| Distribuição irrealista enfraquece queries | Modular por dia/hora; validar com sanidade |
| Esquecer `ANALYZE` pós-seed | Planner usa stats desatualizadas → EXPLAIN da Sprint 02 fica errado |
| PK incompatível com hypertable | PK deve incluir `created_at`; decidir na Story 1.1 |
| Falta de casos divergentes na reconciliação | Garantir fração divergente explícita na Story 1.5 |

---

## Saída para a próxima sprint

Sprint 02 assume `transactions` populada e `ANALYZE`-da, pronta para continuous aggregates, políticas e otimização de queries. `/compact` preservando: schema final, decisão de chunk interval, estratégia de seed e a lista de instituições (será reusada no ClickHouse).

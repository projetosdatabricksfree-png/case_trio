# REPORT — Desafio 1 (Performance e Tuning de Queries)

> Relatório técnico do Desafio 1. **Sprint 01** (esta seção): modelagem do
> TimescaleDB, hypertable e seed de 10M+ transações. As seções de `EXPLAIN
> ANALYZE` das Q1–Q4, continuous aggregates, políticas e a API ClickHouse entram
> nas Sprints 02 e 04.

---

## 1. Modelagem (Sprint 01)

### 1.1 Visão geral

Três entidades no `trio_transactions` (TimescaleDB / PostgreSQL 16):

| Tabela | Papel | Tipo |
|---|---|---|
| `institutions` | dimensão de referência (SSOT de instituições) | tabela regular |
| `accounts` | dimensão de contas (titulares, PII) | tabela regular |
| `transactions` | fato transacional (série temporal de alto volume) | **hypertable** |
| `reconciliation_events` | eventos de conciliação | tabela regular |

DDL idempotente versionado em [`schemas/`](schemas/), aplicado por `make migrate`
(fonte única de verdade; `CREATE … IF NOT EXISTS`, re-roda sem `down -v`).

### 1.2 Decisões de tipos (domínio financeiro)

- **Dinheiro → `numeric(18,2)`** (nunca `float`): evita erro de arredondamento em
  valores monetários. `difference` em `reconciliation_events` é coluna **gerada**
  (`amount_received - amount_expected`), sempre consistente.
- **Tempo → `timestamptz`**: instantes absolutos, base do particionamento temporal.
- **Flexível → `jsonb`** (`metadata`): atributos opcionais sem alterar schema.
- **`status` / `type` → `text` + `CHECK`** em vez de ENUM nativo. Domínio pequeno
  e estável, mas que pode evoluir; `CHECK` evolui via `ALTER` barato, enquanto o
  ENUM nativo trava a evolução (lock de catálogo, sem `DROP VALUE`, ordering
  implícito). Onde a entidade é consultável e reusável (instituições), usamos uma
  **tabela de referência** em vez de constraint.

### 1.3 `institutions` como Single Source of Truth

`institutions` é a SSOT do universo de instituições (~30 instituições BR com código
ISPB). É referenciada por `accounts` (FK) e por `transactions` (soft-ref via
`source_institution` / `destination_institution`) e será **reusada pelo dictionary
do ClickHouse na Sprint 04** (`institution_code → name`). Uma fonte única evita
divergência cross-banco.

### 1.4 Hypertable: chave, FKs e particionamento

**Chave primária `(id, created_at)`.** O TimescaleDB exige que **toda constraint
única de uma hypertable inclua a coluna de particionamento** (`created_at`).
Liderar por `id` preserva o lookup eficiente por id (prefixo do índice).
*Trade-off:* a alternativa "sem PK + índice não-único" economiza um índice único no
load, mas abre mão da garantia de unicidade — inaceitável para um ledger
financeiro, então mantemos a PK.

**FKs fora da hot path (decisão deliberada).** `transactions` **não** declara FK
rígida para `institutions`/`accounts`:
1. FK rígida apontando para/partindo de hypertable adiciona verificação por chunk e
   estrangula o `COPY` de 10M linhas;
2. a integridade é garantida pelo gerador do seed (amostra apenas de códigos/ids
   válidos).
A abordagem de **produção** fica registrada: declarar as FKs como `NOT VALID` e
rodar `VALIDATE CONSTRAINT` pós-carga (valida sem travar a ingestão).

**`reconciliation_events` → `transactions` é soft-ref.** FK rígida apontando para
uma hypertable não é suportada. Guardamos `transaction_id` **+
`transaction_created_at`** (cópia da partition key) para permitir JOIN chunk-local
eficiente com `transactions`.

**Particionamento — `by_range('created_at', INTERVAL '1 day')`:**
- O padrão de consulta concentra-se em 30–90 dias → **chunk exclusion** elimina a
  maioria dos chunks no planner.
- 12 meses ⇒ **365 chunks** (confirmado): granularidade suficiente para compressão
  de chunks 7+ dias e retenção de 90 dias (Sprint 02), sem overhead de chunks
  excessivos.
- Regra geral: o chunk deve caber folgado em memória (~25% da RAM como referência);
  ~27 mil transações/dia estão muito abaixo disso.
- **Sem space partitioning:** em single-node, com este volume, ele só adiciona
  complexidade sem paralelismo real de I/O. Documentado como não-necessário.

Validação:

```text
 hypertable_name | num_dimensions      dimension_number | column_name | time_interval
-----------------+----------------     -----------------+-------------+---------------
 transactions    |              1                     1 | created_at  | 1 day
chunks: 365
```

---

## 2. Seed: estratégia e performance

### 2.1 Arquitetura do gerador

Gerador Python **containerizado** ([`seed/`](seed/), imagem one-shot sob o profile
`tools`), executado por `make seed`. Reprodutível sem Python no host. Distribuições
geradas **vetorizadas com numpy**; RNG semeado (`RNG_SEED`) para reprodutibilidade;
documentos PII (CPF/CNPJ) via `Faker(pt_BR)`. Parametrizável por env
(`SEED_TX`, `SEED_ACCOUNTS`, `RNG_SEED`, …).

### 2.2 Por que `COPY` e não `INSERT`

Carga via **`COPY … FROM STDIN`** (formato texto, em lotes de 500k), ordem de
magnitude mais rápida que `INSERT` linha a linha. Otimizações aplicadas:

- **Defaults no servidor:** `id`, `external_id`, `currency`, `metadata` ficam fora
  do `COPY` (o servidor aplica o DEFAULT) — reduz a largura do stream e tira a
  geração de UUID do laço Python.
- **Carga ordenada por `created_at`:** os timestamps são gerados e **ordenados**
  antes da carga, melhorando compressão e localidade de chunk.
- **Índices secundários pós-seed:** durante o `COPY` mantém-se só a PK; os índices
  de [`06_indexes.sql`](schemas/06_indexes.sql) são criados depois (`make index`) —
  construir de uma vez é mais rápido que manter linha a linha.
- **`ANALYZE` ao final:** estatísticas frescas do planner (crítico para os
  `EXPLAIN ANALYZE` da Sprint 02).

### 2.3 Resultado de performance (10M)

Execução completa medida (`make seed`, 10.000.000 transações + 2.000.000 eventos de
conciliação + `ANALYZE`):

| Métrica | Valor |
|---|---|
| Transações | 10.000.000 |
| Eventos de conciliação | 2.000.000 |
| Contas / instituições | 50.000 / 30 |
| Chunks | 365 |
| Tamanho da hypertable (dados+índices) | ~4,95 GB |
| **Tempo total (seed + ANALYZE)** | **621,5 s (~10min22s)** |

**Abaixo do alvo de < 15 min**, com folga para a fase de `ANALYZE` (~2 min em 365
chunks). Memória do gerador irrisória (vetorização em lotes; geração streaming).

---

## 3. Validação da distribuição (queries de sanidade)

Queries em [`queries/sanity/`](queries/sanity/) (`make sanity`). Saídas reais do
seed de 10M:

**Mix por tipo** (alvo: Pix dominante) — Pix 70,04% · cartão 14,98% · TED 10,00% ·
boleto 4,99%.

**Status** — settled 89,99% · pending 4,99% · failed 3,01% · reversed 2,01%.

**Sazonalidade** — dias úteis ~3,4–3,6k/dia (amostra 20k) contra sábado/domingo
~1,0–1,5k; pico em horário comercial e vale na madrugada.

**Valor (log-normal)** — mediana R$ 88,43 < média R$ 218,61 (cauda à direita); p95
R$ 818,06; máx R$ 82.177,04.

**Latência de liquidação por tipo** — Pix 15,0s · cartão 60,5s · TED ~3.753s (~1h) ·
boleto ~43.531s (~12h). Coerente com a realidade de cada rail.

**Conciliação** — `mismatch` 59.612 (59.502 divergentes) e `missing` 19.886
(todos divergentes): **~79 mil casos com `|difference| > 0,01`**, garantindo
material para a Q2 da Sprint 02.

---

## 4. Como reproduzir

```bash
make up                       # 4 serviços healthy
make migrate                  # schema + hypertable (idempotente)
make seed                     # 10M+ (use SEED_TX=N para variar)
make index                    # índices secundários (pós-seed)
make sanity                   # evidências da distribuição
```

Validação rápida (CI/local): `make seed-smoke` (~20k) no lugar de `make seed`.

---

## 5. Recomendações de produção (registradas, fora do escopo do desafio)

- **FKs de `transactions`** como `NOT VALID` + `VALIDATE CONSTRAINT` pós-carga:
  integridade referencial sem travar a ingestão em massa.
- **PII / LGPD (gancho para RF-1.8):** `accounts.holder_document` e `holder_name`
  são PII; a sanitização de chunks comprimidos entra na Sprint 02.
- **Imagem do seeder pinada por digest** (hoje em faixa de versão) para builds
  bit-a-bit reprodutíveis.
- **Tuning de `chunk_time_interval`** revisitado se o padrão de acesso mudar
  (chunk-alvo ≈ 25% da RAM).

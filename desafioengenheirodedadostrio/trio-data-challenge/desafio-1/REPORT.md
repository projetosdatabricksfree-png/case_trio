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

---
---

# Sprint 02 — Agregados, Políticas & Queries

> Evidência colhida no dataset real de **10.000.000** de transações (TimescaleDB
> 2.28.0, imagem `timescale/timescaledb:latest-pg16`). Cada `EXPLAIN` foi rodado
> com `(ANALYZE, BUFFERS)`; abaixo vai a **análise** dos planos, não o dump cru.

## Decisão transversal — percentis e o TimescaleDB Toolkit (ausente)

`percentile_cont` é um **ordered-set aggregate**: exige o conjunto inteiro e
ordenado na avaliação e **não tem estado parcial combinável**, então o
TimescaleDB **proíbe** seu uso em continuous aggregates (limitação independente
de versão). O percentil aproximado *mergeável* (`uddsketch`/`tdigest`) vive no
**TimescaleDB Toolkit**, que **não está na imagem provisionada**
(`pg_available_extensions` lista só `timescaledb` + `pg_stat_statements`).

**Decisão (alinhada à regra do case — "versões = ambiente fornecido"):** não
troco a imagem nem reseeio 10M. O CAgg B materializa as **estatísticas
mergeáveis nativas** (count/soma/soma de latência/max/settled/failed) e o
**P95/P99 exato** fica numa query companheira (`settlement_percentiles.sql`) com
chunk exclusion. **Produção:** `uddsketch` no CAgg (imagem `timescale/
timescaledb-ha`) — registrado como ADR de ambiente. O custo medido do exato
(17,8 s, abaixo) é a própria justificativa econômica do Toolkit.

## Story 2.1 — Continuous Aggregates (+ refresh policies)

| CAgg | Bucket | Group by | Linhas materializadas | Refresh policy |
|---|---|---|---|---|
| `cagg_volume_by_type_hourly` | 1 h | type, **status** | 121.696 | start 3d · end 1h · 1h (job 1000) |
| `cagg_settlement_by_institution_daily` | 1 d | source_institution | 10.950 (=365×30) | start **7d** · end 1d · 1h (job 1001) |

- **`status` adicionado ao CAgg A** (além de `type`): serve a Q1 (por tipo **e**
  status) direto do agregado. Cardinalidade extra trivial (4×4/hora).
- **`start_offset = 7 dias` no CAgg B** domina a cauda de liquidação: uma
  transação criada hoje pode liquidar (`status='settled'`, `settled_at`) depois —
  UPDATE num bucket de `created_at` já passado gera invalidação; 7d dá folga
  sobre o boleto (~12 h). `end_offset` = 1 bucket (quarentena anti-churn).
- Materialização inicial dos dois (full scan 10M ×2): **81 s**. Jobs de refresh
  confirmados em `timescaledb_information.jobs`.
- **P95/P99 exato** (`settlement_percentiles.sql`, 90 d, `status='settled'`):
  **17,8 s** (sort por grupo de ~2,2 M settled). P95 ≈ 7.000 s, P99 ≈ 70.000 s
  (cauda do boleto). → confirma o trade-off: exato e caro; `uddsketch` o tornaria
  instantâneo a partir do CAgg.

## Story 2.2 — Compressão & Retenção

- **Compressão:** `segmentby = (type, source_institution)`, `orderby =
  created_at DESC`, policy 7 d (job 1002). 5 chunks antigos comprimidos em 3,5 s →
  **razão 5,6×** (79 MB → 14 MB via `chunk_compression_stats`).
  - *Crítica medida do `segmentby`:* 4 tipos × 30 instituições = **120
    segmentos/chunk**; com ~27 k linhas/chunk dá ~228 linhas/segmento (< batch de
    1000 → batches parciais). 5,6× é bom, mas `segmentby = type` sozinho
    provavelmente comprime melhor — mantido conforme a story, trade-off
    registrado. `orderby created_at DESC` grava min/max por batch (exclusão de
    batch por tempo) e serve `ORDER BY created_at DESC LIMIT` sem descomprimir.
- **Retenção:** raw 90 d (job 1003), CAggs 2 anos (jobs 1004/1005). Independência:
  o CAgg materializa numa hypertable separada → dropar o chunk raw **não apaga** o
  agregado (downsample-and-keep). Segurança de ordem: raw 90 d só é seguro porque
  o refresh já materializou, e retenção do CAgg (2a) > raw (90d).
  - **Guard de demo:** a retenção **raw** fica registrada porém **pausada**
    (`scheduled = FALSE`) neste ambiente, senão dropparia ~9 meses do seed e
    destruiria a defesa ao vivo (Q1 de 6 meses, evidências de distribuição).
    Produção: remover o `alter_job` (roda no schedule de 1 dia). Após aplicar
    tudo: **`count(*)` segue 10.000.000**.

## Story 2.3 / 2.4 — Q1–Q4 (EXPLAIN antes/depois)

| Query | Antes (raw/ingênuo) | Depois (otimizado) | Ganho | Alavanca |
|---|---|---|---|---|
| **Q1** volume/valor tipo+status, mês, 6m | **46.170 ms** | **77 ms** (CAgg A) | ~**600×** | rollup do CAgg materializado |
| **Q2** divergências 30d + JOINs | **6.145 ms** | **1.285 ms** | ~**4,8×** | índice parcial + CTE `MATERIALIZED` + bound de chunk exclusion |
| **Q3** top-20 instituições 90d | **3.391 ms** | **8,9 ms** (CAgg B) | ~**380×** | rollup mergeável do CAgg |
| **Q4** duplicatas (janela 5 min) | **721 ms** (Sort 15 MB) | **411 ms** (sem Sort) | Sort eliminado | índice composto p/ a window |

**Q1 — o que mudou no plano.** Antes: `Custom Scan (ChunkAppend)` sobre
`transactions` com **162 chunks excluídos** (predicado em `created_at`), mas ~180
chunks restantes em **Seq Scan + Partial HashAggregate** (≈5 M linhas) →
`Finalize HashAggregate` → **46 s** (1ª leitura fria de chunk = 37 s). Depois:
ChunkAppend sobre `_materialized_hypertable_2` (o CAgg), **16 chunks excluídos**,
Index Scans nos chunks de materialização, ~430 linhas parciais → **77 ms**,
`Buffers: shared hit=4170 read=61`. A "indexação perfeita" da Q1 **é o próprio
CAgg**: nenhum B-Tree no raw vence uma agregação de fração larga.

**Q2 — a lição do misestimate (a mais didática).** A janela é a **data da
transação** (`transaction_created_at`), não `reconciled_at` (o seed gravou
`reconciled_at` uniforme = `now()`, logo não-seletivo — em produção acompanha a
transação). Três alavancas, **todas necessárias**:
1. **Índice parcial** `idx_recon_divergent (transaction_created_at) WHERE
   difference > 0.01 OR difference < -0.01` — indexa só as **79 k** divergências
   de 2 M; o range de 30 d as corta a **6.243**. Tamanho: **1,75 MB**.
2. **CTE `MATERIALIZED`** — *barreira de otimização* que **força** o uso do
   índice. Sem ela o planner **subestima** a seletividade do `OR` sobre a coluna
   **GERADA** `difference` (estima `rows=1`) e cai num **Parallel Hash Join que
   varre os 10M** → adicionar só o índice **não basta** (ficou em ~2,5 s ainda
   varrendo). Com a CTE: `Index Scan using idx_recon_divergent` → 6.242 linhas em
   **24 ms**.
3. **Bound redundante** `t.created_at >= now()-30d` (idêntico via a igualdade do
   join) — restaura **chunk exclusion** no lado transactions (`ConstraintAware
   Append → Merge Append` em ~30 chunks via Index Scan), em vez de varrer a
   hypertable. (Cuidado provado na prática: CTE **sem** esse bound explode para
   **82 s** com cross-product de 156 M linhas, pelo mesmo `rows=1`.)
   Resultado: **6.145 → 1.285 ms**. Resultado correto: **6.243** divergências.

**Q3 — CAgg B serve tudo menos o tail.** Antes: `Parallel Custom Scan
(ChunkAppend)`, **2 workers**, ~2,45 M linhas em ~90 chunks, `Gather Merge` →
3,4 s. Depois: rollup de 90×30 = 2.700 linhas do CAgg → **8,9 ms**. Métricas
mergeáveis: volume=`sum(total_amount)`, latência média=`sum(sum_latency_s)/
sum(settled_count)` (por isso **não** materializamos `avg` direto), taxa de
falha=`sum(failed_count)/sum(tx_count)`.

**Q4 — `LAG` vs self-join e a eliminação do Sort.** Escolhido **window function
`LAG`** (passe único O(n), sem risco quadrático do range self-join em chaves
quentes). Antes: `ChunkAppend → Sort (quicksort 15 MB) → WindowAgg` = 721 ms.
Depois, com `idx_tx_dedup (amount, source_institution, destination_institution,
created_at)`: as 3 chaves casam o `PARTITION BY` e `created_at` dá o `ORDER BY` →
**`Custom Scan (ConstraintAwareAppend) → Merge Append` (Sort Key = amount, src,
dst, created_at) → `WindowAgg`**, com **`Index Only Scan` (Heap Fetches: 0)** e
**sem nó `Sort`**. 721 → **411 ms**. Encontrou **2 duplicatas naturais** em 7 dias
(coincidências exatas de valor+origem+destino em ≤5 min são raras — sinal
saudável). Ordem das colunas é o ponto: igualdade primeiro (partição), tempo por
último (ordenação) — invertê-la perderia a eliminação do Sort.

**O que procurar no `EXPLAIN` (checklist usado acima):** `Chunks excluded`
(exclusão temporal), `Custom Scan (ChunkAppend/ConstraintAwareAppend)`,
`Merge Append` (append ordenado → sem Sort), `Index Only Scan` com
`Heap Fetches: 0` (cobertura total), desaparecimento do nó `Sort`,
`Rows Removed by Filter` caindo, `Buffers: shared read/hit` (I/O — a prova mais
forte) e `Workers Launched` (paralelismo nas agregações inevitáveis do raw).

## Story 2.5 — Série temporal com gapfill (48 h)

`time_bucket_gapfill('1 hour', …)` gera os 48 buckets contínuos. Três tratamentos
da mesma métrica, evidenciados no edge pós-dados (`now()` = 2026-06-22 14:33; dado
acaba em 2026-06-21 23:59):

| bucket (gap) | `coalesce(count,0)` | `locf(count)` | `interpolate(count)` |
|---|---|---|---|
| 2026-06-22 02:00 … 13:00 | **0** (correto p/ fluxo) | **177** (degrau — errado p/ volume) | *(NULL — sem âncora futura)* |

**Decisão:** volume é métrica de **fluxo** → gap = **zero real** (`COALESCE 0`).
`locf` (degrau) vale para métricas de **nível/estado**; `interpolate` (rampa) para
sinais contínuos amostrados. Para volume, `locf` sustentaria volume fantasma à
noite e `interpolate` inventaria rampa — ambos semanticamente errados.

## Story 2.6 — Sanitização LGPD de chunks comprimidos

- **Mitigação primária (vault/surrogate):** a PII vive em `accounts` (dimensão
  **não-comprimida**); `transactions` só tem o UUID substituto. Esquecimento =
  `UPDATE`/`DELETE` indexado em `accounts` → **O(1)**, sem descomprimir nada.
  Demonstrado (em transação revertida): `holder_name`/`holder_document` →
  `[ANONIMIZADO-LGPD]`.
- **Runbook (fallback) p/ PII em chunk comprimido**, demonstrado ponta-a-ponta no
  `_hyper_1_366_chunk`: `is_compressed=t` → **`decompress_chunk` (0,7 s)** → mask
  (`UPDATE … metadata - 'cpf' - 'holder_name'`) → **`compress_chunk` (0,6 s)** →
  `is_compressed=t`, **9.436 linhas preservadas**. Riscos (escopar a chunks
  específicos, janela de manutenção, storage ~2× e I/O na descompressão) e a
  preferência por sanitização **em lote** documentados em `lgpd_sanitization.sql`.

## Índices criados nesta sprint (justificativa)

| Índice | Tabela | Para | Por quê / ordem |
|---|---|---|---|
| `idx_recon_divergent` (parcial) | reconciliation_events | Q2 | `(transaction_created_at) WHERE divergente`: só ~79 k linhas; range 30d → 6 k; tempo 1º (range) |
| `idx_tx_dedup` (composto) | transactions | Q4 | `(amount, source, destination, created_at)`: igualdade→PARTITION, tempo→ORDER, elimina Sort |

Build dos dois em **23 s** sobre 10 M; `ANALYZE` em seguida (estatísticas para o
planner — crítico para os planos acima).

---
---

# Sprint 03 — PostgreSQL Legado & Migração

> Banco **`trio_legado`** (PostgreSQL 16, `postgres:16-bookworm`), separado do
> TimescaleDB. Evidência colhida com o seed default: **30 configs · 61 parceiros ·
> 30.000 users · 39.000 accounts · 39.000 limits** (carga em **2,3 s**). `EXPLAIN
> (ANALYZE, BUFFERS)`; abaixo a análise dos planos.

## Decisões de modelagem

- **Banco separado → referência duplicada da SSOT.** Sem FK cross-database, a lista
  de instituições é materializada aqui em `institution_configs`, mas **gerada da
  mesma `institutions.py`** que alimenta o TimescaleDB — single source no gerador.
  `institution_configs.institution_name` é a fonte do dictionary do ClickHouse
  (Sprint 04).
- **Chaves `bigint GENERATED ALWAYS AS IDENTITY`** (contraste com o UUID do schema
  moderno). É um "cheiro de legado" deliberado e tem consequência real na migração:
  **sequências de IDENTITY precisam de reconciliação no cutover** (ver
  `migration-analysis.md`).
- **PII confinada a `users`** (`document`, `full_name`) — mesmo princípio de vault da
  Sprint 02 (esquecimento LGPD é `UPDATE`/`DELETE` indexado por id).
- **FKs sem índice no schema base**, de propósito: o Postgres **não** indexa FK
  automaticamente, então o "antes" do `EXPLAIN` mostra o custo real; os índices de
  apoio entram pós-seed (`make index-legado`, `06_indexes_legacy.sql`).

## Story 3.2 — Relatório de contas ativas por instituição

`report_active_accounts.sql` — agrega contas ativas, saldo total/médio por
`(instituição, tipo)`. Índice: `idx_accounts_active_cover` — **parcial**
(`status='active'`) + **cobertura** (`INCLUDE balance`) em `(institution_code,
account_type)`.

| Cenário | Plano | Buffers | Tempo |
|---|---|---:|---:|
| Relatório completo — ANTES (sem índice) | Seq Scan + HashAggregate + Sort | 488 | 33,6 ms |
| Relatório completo — DEPOIS (com índice) | **Seq Scan mantido** (planner ignora o índice) | 488 | 17,5 ms |
| Drill-down 1 instituição — DEPOIS | **Index Only Scan** (`Heap Fetches: 0`) | **25** | **1,0 ms** |

**Leitura honesta:** para o relatório completo o planner **corretamente mantém o Seq
Scan** — `status='active'` cobre 93% das linhas (predicado não seletivo) e a relação
tem só ~488 páginas, então varrer o índice custaria páginas equivalentes com I/O
aleatório. **Indexar por reflexo seria anti-padrão.** O índice paga no **caminho de
acesso seletivo** (drill-down por instituição): aí vira `Index Only Scan` com
`Heap Fetches: 0`, **488 → 25 buffers** e **33,6 → 1,0 ms**.

Drill-down reproduzível:
```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT a.account_type, count(*), round(sum(a.balance),2), round(avg(a.balance),2)
FROM accounts a
WHERE a.institution_code = '00000000' AND a.status = 'active'
GROUP BY a.account_type;
```

## Story 3.3 — Lookup operacional (join de 5 tabelas)

`config_lookup.sql` — contas ativas acima do limite diário, em instituições ativas
que liquidam em **D+1**, com seu **acquirer** ativo:
`institution_configs ⋈ accounts ⋈ users ⋈ account_limits ⋈ institution_partners`.
Índices de FK: `idx_accounts_institution`, `idx_accounts_user`,
`idx_partners_institution`.

| Cenário | Plano (driver) | Buffers | Tempo |
|---|---|---:|---:|
| Multi-instituição — ANTES | 4× Hash Join + Seq Scan accounts (36 k) | 1.216 | 22,9 ms |
| Multi-instituição — DEPOIS | **Nested Loop** dirigido pelas 12 D+1 + **Bitmap Index Scan** em accounts | 4.711 | 19,5 ms |
| Drill-down 1 instituição — DEPOIS | Nested Loop + Bitmap Index Scan (`Heap Blocks 467`) + `users_pkey` | — | 13,6 ms |

**Leitura honesta:** com `idx_accounts_institution` o planner **pivota** do Hash Join
(Seq Scan de accounts) para um **Nested Loop dirigido pelas 12 instituições D+1**,
com `Bitmap Index Scan` em accounts. Em **39 k linhas residentes em cache** o ganho é
de **plano/escala, não de buffers brutos** — os buffers até sobem (re-leitura por
instituição no bitmap). O valor do índice é o **caminho de acesso**: no drill-down de
uma instituição, o `Bitmap Index Scan` lê só **~467 páginas** das contas daquela
instituição em vez de varrer as 39 k — e cresce com o volume / com filtros mais
estreitos. A FK `accounts.user_id` indexada sustenta o `Index Scan using users_pkey`
no laço.

**Princípio transversal (Sprint 03):** em relação pequena e cache-resident, **o
planner está certo ao preferir Seq Scan/Hash Join** para varreduras amplas; índices
servem **acesso seletivo**. Documentar *por que um índice não é usado* é tão sênior
quanto exibir o ganho quando ele é.

## Índices criados nesta sprint (justificativa)

| Índice | Tabela | Para | Por quê / ordem |
|---|---|---|---|
| `idx_accounts_active_cover` (parcial + cobertura) | accounts | Q3.2 | `(institution_code, account_type) INCLUDE (balance) WHERE status='active'`: Index Only Scan no drill-down |
| `idx_accounts_institution` | accounts | Q3.3 | FK crua; dirige o join a partir das instituições filtradas (Bitmap Index Scan) |
| `idx_accounts_user` | accounts | Q3.3 | FK crua; sustenta o join accounts↔users |
| `idx_partners_institution` | institution_partners | Q3.3 | FK crua; join partners↔configs |

`ANALYZE` rodado após o seed (no `run_legacy.py`) e após os índices (`make
analyze-legado`) — sem estatísticas atualizadas o planner decide errado.

## Migração (Story 3.4)

`migration-analysis.md`: opções (EC2 · **RDS Multi-AZ** · Aurora), matriz de
critérios e **recomendação de RDS Multi-AZ** para legado de referência/baixo volume
(Aurora só com gatilho de escala de leitura/DR). Estratégia de **downtime mínimo**
(replicação lógica nativa › AWS DMS › Blue/Green), **runbook de 72h** e
**riscos/rollback** — com destaque para a **reconciliação de sequências/IDENTITY**,
consequência direta da decisão de chaves deste schema.

---

# Sprint 04 — ClickHouse: Motor de Dados

> Banco analítico **`trio_analytics`** (ClickHouse `latest`). Schema, 2 MVs e o
> dictionary aplicados por **`make migrate-ch`** (idempotente). Carga via **loader
> Python que reusa `generators.py`** — a MESMA SSOT de distribuições do TimescaleDB.
> Evidência de performance colhida com **50 milhões** de transações (`make seed-ch`
> com `CH_SEED_TX=50000000`). O ClickHouse serve **dois públicos**: dashboards
> (Grafana) e aplicação (API FastAPI).

## Por que `make migrate-ch` e não `init/clickhouse/`

Espelha a decisão das Sprints 01/03: `init/` só roda na **1ª criação do volume** e
não pode depender de outro serviço. O **dictionary lê do `postgres-legado`**
(`institution_configs`), que só existe **após `seed-legado`** — uma dependência
cross-serviço que o `init/` não resolve. Aplicar por `make` (pós-`up --wait`,
pós-seed) é robusto, re-executável e **defensável ao vivo**. `init/clickhouse/`
mantém apenas `CREATE DATABASE`.

## Story 4.1 — Engine, `ORDER BY`, partição e codecs

- **`ENGINE = ReplacingMergeTree(version)`** — transações mudam de status sem
  `UPDATE`: a última versão (maior `version` = `updated_at`) vence no merge.
  Descartados: `MergeTree` (sem dedup → versões antigas vazam), `AggregatingMergeTree`
  (é para as MVs), `CollapsingMergeTree` (exige `sign` e reenviar o estado anterior —
  frágil para o pipeline idempotente da Sprint 05).
- **`ORDER BY (source_institution, type, created_at, id)`** é a chave de ordenação
  **e de dedup**. Todas as colunas são **imutáveis por transação** (só
  `status`/`settled_at`/`version` mudam), então a tupla é **1:1 com `id`** e o
  Replacing colapsa exatamente as versões da *mesma* transação. A ordem
  (instituição → tipo → tempo) casa com os filtros dos Data Champions e com a query
  flagship → **poda de granules**. Alternativa liderada por tempo
  (`toDate(created_at), …`) favoreceria varreduras temporais puras, mas perderia a
  seletividade por instituição/tipo que domina aqui.
- **`PARTITION BY toYYYYMM(created_at)`** — mensal: poda forte de janelas recentes sem
  explodir o nº de partes (diária geraria partes demais; anual poda fraca).
- **Codecs/tipos:** `Delta, ZSTD` em `created_at`/`version` (quase monotônicos);
  `LowCardinality(String)` em `status`/`type`/`institution`/`currency` (dicionário
  interno → menos I/O e filtro mais rápido); `Decimal(18,2)` no dinheiro (nunca float
  no schema); `id`/`external_id` `DEFAULT generateUUIDv4()` → gerados no servidor,
  fora do INSERT da carga (mesmo truque do seed do TimescaleDB).

## Story 4.2 — Materialized Views (AggregatingMergeTree + States/Merge)

Duas MVs gravam **estados parciais** de agregação na inserção; a leitura finaliza com
`-Merge` (combinar estados é barato → dashboards não reprocessam a base):

- **`mv_tx_daily_summary`** → `tx_daily_summary` por `(dia, instituição, tipo)`:
  `countState/sumState/avgState/quantileState(0.95)` sobre `amount`. Leitura:
  `countMerge/sumMerge/avgMerge/quantileMerge(0.95)`.
- **`mv_tx_status_funnel`** → `tx_status_funnel` por `(dia, tipo, status)`: `countState`
  + `avgStateIf(latência, isNotNull(settled_at))`. As latências batem com o gerador:
  **pix ≈ 15 s · card ≈ 60 s · ted ≈ 3.7 k s · boleto ≈ 43 k s**; `pending`/`failed`
  ficam `NULL` (sem liquidação).

**Caveat honesto (gancho da Sprint 05):** a MV processa o **bloco inserido, antes do
dedup** do ReplacingMergeTree. Na carga estática desta sprint cada transação entra
**uma vez** (estado final) → agregados exatos. No pipeline contínuo, reinserir a mesma
tx (`pending→settled`) faria a MV **contar em dobro** — mitigação (alimentar a MV de
fonte deduplicada, ou agregar só a versão terminal) registrada para a Sprint 05.

## Story 4.3 — Dictionary (`dictGet`) vs JOIN

`dict_institutions` (`institution_code → institution_name`, …) tem **fonte
`POSTGRESQL(postgres-legado.institution_configs)`** — fecha o gancho da Sprint 03: a
referência tem **uma origem** (SSOT → legado) e o ClickHouse a consome em memória.
`LAYOUT(COMPLEX_KEY_HASHED())` (chave `String`), `LIFETIME(MIN 300 MAX 600)` para
refresh automático. **`dictGet` > JOIN** aqui: lookup **O(1) em memória** de ~30
linhas de referência que mudam pouco, sem hash join nem ler a tabela do disco; JOIN só
compensaria para tabelas grandes/voláteis. Em uso na flagship, na API e em
`dict_lookup_demo.sql`.

> **Segredo fora do repo:** o `.sql` commitado usa o placeholder `__PG_PASSWORD__`;
> `make migrate-ch` injeta `POSTGRES_PASSWORD` do `.env` via `sed` no apply. Mais limpo
> que `datasources.yml` (que hoje commita a senha dev — dívida pré-existente).

## Story 4.4 — Query Grafana sub-segundo (flagship)

`grafana_pix_success.sql` — taxa de sucesso **Pix por instituição por hora** nas
últimas 24h + **delta %** vs o mesmo horário do dia anterior. Ancorada a
**`max(created_at)`** (seed estático) e enriquecida com `dictGet`. **Servida da tabela
raw** (sem MV): `type='pix'` + janela de 48h são altamente seletivos.

| Métrica (50M linhas · 3,49 GiB · medido em `system.query_log`) | Valor |
|---|---:|
| Tempo — **cold** (1ª execução) | **514 ms** |
| Tempo — **warm** | **87–119 ms** |
| Linhas lidas | **689 mil de 50M → 1,38%** |
| Bytes lidos | **6,84 MiB de 3,49 GiB** |
| Linhas no resultado | 715 |

Sub-segundo confortável: a query lê **1,38% da tabela** (689k de 50M linhas) e
**6,84 MiB**. A poda funciona em duas camadas: `PARTITION BY toYYYYMM` elimina meses fora da janela;
o `ORDER BY (source_institution, type, created_at, …)` poda **granules** dentro de cada
prefixo `(instituição, pix)` — só uma fração mínima das linhas é lida. O design
**sustenta sub-segundo até centenas de milhões**: a janela de 48h é ~0,5% de um ano de
dados, então o custo cresce com o *tamanho da janela*, não com o total da tabela.
(Otimização futura registrada: MV horária de sucesso para um dashboard always-on.)

## Story 4.5 — API: ClickHouse servindo aplicação (RF-3.5)

FastAPI (`desafio-1/api/`, serviço `api` no compose, porta 8000), `clickhouse-connect`,
**queries parametrizadas** (binders `{name:Type}` → sem SQL injection):

- `GET /transactions/volume/realtime?window_minutes=N` → volume agregado recente
  (count, soma, breakdown por tipo) — **painel de operações**.
- `GET /institutions/{code}/health?window_minutes=N` → taxa de sucesso/falha recente da
  instituição, **nome via `dictGet`** — **regra de negócio**.

Ambos ancorados a `max(created_at)`. `/health` não toca o ClickHouse (liveness do
compose). Demonstra que o ClickHouse serve **aplicação**, não só dashboard.

```bash
curl -fsS "http://localhost:8000/transactions/volume/realtime?window_minutes=60" | jq
curl -fsS "http://localhost:8000/institutions/00000000/health?window_minutes=1440" | jq
```

## Story 4.6 — Carga e validação do dedup

- **Loader** (`seed_clickhouse.py`): reusa `generators.py`; gera por lotes e insere via
  `clickhouse-connect` `insert_df` (datetime64/NaT vetorizados). `id`/`external_id`/
  `currency` ficam fora do INSERT (DEFAULT no servidor); `version = max(created_at,
  settled_at)`. Idempotente (TRUNCATE base + targets antes de carregar). Escala por env
  (`CH_SEED_TX`); o schema (`migrate-ch`) roda **antes** → as MVs materializam na carga.
  Throughput medido: **50M em 525 s (~95k linhas/s)** com as 2 MVs agregando em linha.
- **Dedup do ReplacingMergeTree** (`replacing_dedup_demo.sql`, tabela descartável p/ não
  sujar a carga): dois INSERTs (`pending` v1, `settled` v2) → `count() = 2` **antes**;
  `count() FINAL = 1` (`settled`, maior `version`); `OPTIMIZE … FINAL` faz o merge
  físico → 1 linha. `make optimize-ch` valida o dedup na tabela principal.

## Reproduzir / validar (Sprint 04)

```bash
make up                         # 5 serviços healthy (inclui a API)
make migrate-legado seed-legado # institution_configs (fonte do dictionary)
make migrate-ch                 # tabela + 2 MVs + dictionary (idempotente)
CH_SEED_TX=50000000 make seed-ch    # carga (suba p/ 100M+ no headline)
make queries-ch                 # flagship + dictGet + reads -Merge + dedup
make optimize-ch                # OPTIMIZE FINAL (valida dedup)
```

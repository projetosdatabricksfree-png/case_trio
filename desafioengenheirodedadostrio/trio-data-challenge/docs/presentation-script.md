# Roteiro de apresentação ao vivo (30–45 min)

> Sprint 07 · Story 7.5. Demo via **terminal + dashboards** (sem slides obrigatórios). Comandos
> prontos para colar — evitar improviso ao vivo. Premissa do avaliador: *"queremos profundidade real,
> não output de LLM"* — então cada comando vem com **a decisão por trás**.

## Pré-voo (antes de começar, fora do relógio)

```bash
cd desafioengenheirodedadostrio/trio-data-challenge
make up && make smoke                          # 6 serviços healthy
# Ambiente já semeado e sincronizado (ver validation-checklist.md). Se for do zero:
# make migrate seed-smoke index caggs policies migrate-legado seed-legado \
#      migrate-ch seed-ch-smoke migrate-pipeline pipeline-once
```
Abrir: Grafana http://localhost:3000 (admin/admin, pasta **Trio**) e a API http://localhost:8000/docs.

---

## Parte 1 — Ambiente rodando (8–10 min)

**Objetivo:** provar que sobe do zero e que os dados são reais.

```bash
docker compose ps                              # 6 serviços healthy
make sanity                                    # distribuição do seed (Pix dominante, status, sazonalidade)
```
- **Falar:** 3 bancos por **propósito**, não por modismo — TimescaleDB (OLTP série temporal),
  PostgreSQL legado (referência/config), ClickHouse (OLAP). Seed via `COPY` (10M < 15 min), `numpy`
  vetorizado, RNG semeado → reprodutível.

```bash
make queries                                   # Q1–Q4 com EXPLAIN antes/depois
```
- **Mostrar o ganho e a causa:** Q1 46.170 ms → **77 ms** (~600×) servida do **CAgg**, não de um
  índice — "a indexação perfeita da Q1 é o próprio continuous aggregate". Q2 é a mais didática: índice
  parcial **+** CTE `MATERIALIZED` **+** bound de chunk exclusion, as três necessárias (o planner
  subestima o `OR` sobre coluna gerada). Q4 elimina o `Sort` com índice composto (igualdade→partição,
  tempo→ordenação).

```bash
make queries-ch                                # flagship ClickHouse sub-segundo
curl -fsS "http://localhost:8000/transactions/volume/realtime?window_minutes=60" | jq
```
- **Falar:** flagship lê **1,38% da tabela** (poda por `PARTITION BY toYYYYMM` + granules do
  `ORDER BY`); a API prova **ClickHouse servindo aplicação**, não só dashboard. `dictGet` O(1) em vez
  de JOIN para o nome da instituição.

**Dashboards (Grafana):** abrir os 4 (TimescaleDB, Pipeline, ClickHouse, Postgres legado). ≥2 leem o
ClickHouse (critério mínimo). Mostrar o dashboard de **pipeline** (lê `pipeline_runs`).

---

## Parte 2 — Decisões de arquitetura & modelagem (8–10 min)

**Pipeline (o coração).** Abrir [`desafio-2/ADR.md`](../desafio-2/ADR.md) e o diagrama
[`as-built`](../desafio-2/diagrams/architecture.md).
- **Micro-batch idempotente**, não CDC: 100% demonstrável no compose; CDC (Debezium + MSK) é a
  evolução-alvo com o **mesmo contrato de dados**.
- **Idempotência = watermark + `ReplacingMergeTree(version)`.** Duas passadas: INSERT por janela de
  `created_at` (poda de chunk na hypertable comprimida) + MUTATE por keyset `settled_at` (capta
  `pending → settled`). `id` da origem carregado explicitamente → o Replacing deduplica.

```bash
make pipeline-once && make pipeline-once        # idempotência: rodar 2x
docker compose exec -T clickhouse clickhouse-client --user trio --password trio2024 \
  -d trio_analytics -q "SELECT count() FROM transactions FINAL"   # não muda na 2ª rodada
make pipeline-mutation-demo                      # pending -> settled refletido, sem duplicar
```
- **Trade-off honesto:** a MV conta o bloco **antes** do dedup → re-sincronizar uma mutação conta em
  dobro na MV. MV serve **tendência**; contabilidade exata usa a raw com `FINAL`/`argMax`.

**Modelagem que defende escolhas pelo plano:** no legado (Sprint 03) o planner **mantém Seq Scan** no
relatório completo (relação pequena, cache-resident) e só usa índice no **drill-down** — "documentar
por que um índice **não** é usado é tão sênior quanto exibir o ganho quando ele é".

---

## Parte 3 — Incidente SEV-1 (8–10 min)

**Cenário:** 06h47, dashboards Pix (ClickHouse) com **volume zero há ~2h**; TimescaleDB normal. Na
noite anterior: manutenção no TS **e** mudança de security group.

```bash
make incident-demo                               # reproduz o incidente e a resolução
```
- **Narrar junto com a saída:** o script para o pipeline (*stand-in do SG que cortou a rede*), injeta
  novas transações no TS → CH fica stale → **investigação** (TS `max(created_at)` recente × CH
  defasado × última run parada — isola a camada: é o **pipeline**, não o CH) → resolução (pipeline
  drena) → **convergência CH == TS**.
- **Árvore de hipóteses** ([`incident-response.md`](../desafio-3/incident-response.md)), ordenada
  ligando os **dois** eventos: (1) SG bloqueou o pipeline *(mais provável)*; (2) pipeline morreu na
  manutenção sem restart; (3) compressão interferiu na leitura *(improvável pelo design)*; (4) SG
  isolou o CH dos inserts; (5) credenciais/IAM/SSL; (6) cauda (merges/TZ).
- **Pós-incidente:** a falha foi de **detecção** (2h). Alerta de lag agressivo + volume=0 SEV-1 (já na
  Sprint 06) pegariam em minutos; SG via IaC com canary; restart policy do pipeline.

---

## Perguntas-âncora (respostas preparadas)

**1. "E se o volume triplicasse / 10x, o que mudaria na arquitetura?"**
> Pipeline: micro-batch → **CDC (Debezium + Amazon MSK)**, **tópico/partição por instituição** →
> latência de segundos e throughput horizontal; consumers idempotentes mantêm o dedup.
> ClickHouse: `MergeTree` → **`ReplicatedMergeTree` + sharding** (HA + escala de escrita/leitura).
> TimescaleDB: revisar **chunk interval**, mais compressão, **read replicas** para isolar a leitura do
> pipeline do OLTP. O **contrato de dados não muda** (ver [ADR §2](../desafio-2/ADR.md)).

**2. "Como adicionar um novo consumer no ClickHouse sem impactar os existentes?"**
> Nova **MV + tabela destino** própria (ou nova `ReplacingMergeTree`/`AggregatingMergeTree`) lendo a
> base — a MV materializa no INSERT **sem tocar** o pipeline nem as tabelas atuais. Grants
> read-only para o consumer. Isolamento: cada consumer tem seu destino e seu ciclo de merge; a base é
> append-only. Nada de alterar o schema das tabelas existentes.

**3. "Como migrar a engine de uma tabela ClickHouse em produção sem downtime?"**
> Padrão **shadow + swap atômico**: (a) criar `transactions_new` com a engine destino; (b) **MV de
> backfill** + `INSERT … SELECT` para popular do histórico; (c) **dual-write** (apontar o pipeline
> também para a nova) até o lag zerar; (d) validar paridade (`count`, `FINAL`/`argMax`, amostras);
> (e) **`RENAME TABLE transactions TO transactions_old, transactions_new TO transactions`** (troca
> atômica); (f) descartar a antiga após período de guarda. Sem downtime — leitura nunca para.

**4. "Estratégia para onboardar um Data Champion novo no Grafana?"**
> Datasource **read-only** (user com `GRANT SELECT`); dashboards e MVs prontos (pasta **Trio**
> provisionada como JSON); **dictionaries** para nomes amigáveis (`institution_code → name` via
> `dictGet`); guia de boas práticas de query (filtrar por **partição**/`ORDER BY`, usar as MVs para
> tendência e a raw + `FINAL` para exatidão). Governança: nada de `SELECT *` sem filtro de tempo.

**5. "Migrar o PostgreSQL legado para Aurora amanhã — plano de 72h?"**
> Ver [`migration-analysis.md`](../desafio-1/migration-analysis.md). Recomendação: **RDS Multi-AZ**
> (legado de baixo volume); Aurora só com gatilho de escala/DR. Caminho de **downtime mínimo**:
> replicação lógica nativa (ou **AWS DMS** full-load + CDC) → **runbook 72h** (0–24h prep; 24–60h
> replicação + paridade + **reconciliação de sequências IDENTITY**; 60–72h cutover por connection
> string/DNS) → **rollback** mantendo a origem read-only / Blue-Green como troca de ponteiro.

---

## Encerramento

> "Tudo que mostrei sobe com `docker compose up` e roda no **CI a cada push** — o job de integração
> executa exatamente esta demo. Documentação é cidadã de primeira classe: cada decisão tem o *porquê*
> e o *trade-off* registrados. Se não está documentado, não existe."

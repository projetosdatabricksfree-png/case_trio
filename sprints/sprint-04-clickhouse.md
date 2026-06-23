# Sprint 04 — ClickHouse: Motor de Dados

> **Dias:** 3–4 · **Peso:** Profundidade Técnica (40%) · **Stories:** 6
> **Cobre:** RF-3.1 a RF-3.5 · **Desafio 1 / Parte C**
> **Objetivo:** Schema ClickHouse com engine/ordenação/particionamento justificados, materialized views pré-agregando, dictionary em uso, query Grafana sub-segundo, e API servindo o ClickHouse diretamente para aplicação.

---

## Contexto

ClickHouse é o motor que serve **dois públicos**: Data Champions (dashboards) e aplicações (API, regras de negócio). As decisões de engine e `ORDER BY` impactam diretamente a performance de ambos — e valem nota técnica. O destaque é a query Grafana **sub-segundo em centenas de milhões de registros** e a demonstração de que ClickHouse serve **aplicação**, não só dashboard.

**Depende de:** Sprint 00 (ClickHouse saudável), Sprint 01 (lista de instituições), Sprint 03 (fonte dos dictionaries).
**Habilita:** Sprint 05 (pipeline escreve aqui), Sprint 06 (dashboards/alertas leem daqui).

---

## Definition of Done da Sprint

- [x] Schema `transactions` no ClickHouse com engine, `ORDER BY`, `PARTITION BY` e compressão justificados.
- [x] 2 materialized views (resumo diário + funil de status) materializando corretamente.
- [x] Dictionary (institution_code → name) criado, carregado e usado em query.
- [x] Query Grafana (sucesso Pix por instituição/hora + delta % vs dia anterior) rodando sub-segundo.
- [x] API FastAPI servindo volume em tempo real do ClickHouse, retornando JSON.
- [x] Dados de teste suficientes para validar performance (50M carregados + projeção p/ 100M+).

---

## Story 4.1 — Schema `transactions` e escolha de engine

**Descrição:** Modelar a tabela transacional no ClickHouse com decisões de engine e layout justificadas.

**Tarefas:**
- **Engine:** `ReplacingMergeTree(version)` para `transactions`.
  - Justificar: transações mudam de status (`pending → settled`). `ReplacingMergeTree` com coluna `version` (ex: timestamp de atualização) mantém a última versão por chave, sem `UPDATE` real. Contrastar com `MergeTree` puro (sem dedup), `AggregatingMergeTree` (para MVs) e `CollapsingMergeTree` (alternativa para mutação — explicar por que Replacing é mais simples aqui).
- **`ORDER BY`** (= chave primária no ClickHouse): decidir baseado nos padrões de consulta.
  - Candidato: `(toDate(created_at), type, source_institution, external_id)` ou `(source_institution, toStartOfHour(created_at), type)`.
  - Justificar pela cardinalidade e pelos filtros mais comuns (Data Champions filtram por instituição/tipo/tempo; a query Grafana filtra Pix por instituição por hora). A primeira coluna do `ORDER BY` deve ser a mais usada em filtros de range/igualdade.
- **`PARTITION BY`**: `toYYYYMM(created_at)` (partição mensal) — equilíbrio entre número de partes e poda de partição. Justificar (partição diária geraria partes demais; anual, poda fraca).
- **Compressão por coluna** onde aplicável: `CODEC(Delta, ZSTD)` para timestamps/sequenciais, `CODEC(ZSTD)` default; `LowCardinality(String)` para `type`/`status`/`currency`/`institution`. Explicar o ganho de `LowCardinality` em colunas de baixa cardinalidade.
- Coluna `version` (`updated_at` ou similar) para o ReplacingMergeTree.

**Critério de aceitação:** tabela criada; decisões documentadas (engine, ORDER BY, PARTITION BY, codecs) com justificativa ligada a padrões de consulta.

**Artefatos:** `init/clickhouse/02_transactions.sql`, seção no `desafio-1/REPORT.md` (parte ClickHouse).

---

## Story 4.2 — Materialized views (resumo diário + funil de status)

**Descrição:** Criar as duas MVs exigidas para pré-agregação.

**Tarefas:**
- **MV A** — resumo diário por instituição e tipo: contagem, soma, média, **p95 de valor**.
  - Destino `AggregatingMergeTree`; usar estados de agregação (`sumState`, `countState`, `avgState`, `quantileState(0.95)`) na MV e funções `-Merge` na leitura.
  - Explicar o padrão *MV + AggregatingMergeTree + States/Merge* (por que armazenar estados em vez de valores finais).
- **MV B** — funil de status (`pending → settled/failed/reversed`) com tempo médio em cada estágio.
  - Modelar transição de estados; calcular tempo médio entre `created_at` e `settled_at`/timestamp de transição por estágio.
  - Discutir a limitação: ClickHouse não tem "update"; o funil é derivado de eventos/versões — explicar a abordagem (ex: agregação sobre a última versão por transação, ou tabela de eventos de status).

**Critério de aceitação:** ambas as MVs materializam ao inserir; leitura com `-Merge` retorna agregados corretos; p95 funcional.

**Atenção:** MV no ClickHouse só processa **inserts novos** após sua criação — para popular histórico, fazer `INSERT INTO mv_target SELECT ...` a partir da tabela base, ou criar a MV antes de carregar dados.

**Artefatos:** `init/clickhouse/03_mv_daily_summary.sql`, `04_mv_status_funnel.sql`.

---

## Story 4.3 — Dictionary e uso em query

**Descrição:** Implementar um dictionary e demonstrar quando ele supera JOIN.

**Tarefas:**
- Dictionary `dict_institutions` (institution_code → institution_name), fonte:
  - Opção pragmática para o demo: `SOURCE(CLICKHOUSE(...))` lendo uma tabela local de instituições, **ou** `SOURCE(POSTGRESQL(...))` apontando para `institution_configs` do legado (mais fiel à arquitetura — o pipeline de referência da Sprint 05 mantém isso atualizado).
  - `LAYOUT(HASHED())`, `LIFETIME(...)` para refresh.
- Demonstrar uso em query: `dictGet('dict_institutions', 'institution_name', source_institution)` enriquecendo resultados sem JOIN.
- **Explicar quando dictionaries > JOIN no ClickHouse:** lookups de baixa cardinalidade carregados em memória são O(1) e evitam o custo de hash join distribuído; ideal para dados de referência que mudam pouco. JOIN faz sentido para tabelas grandes/voláteis.

**Critério de aceitação:** dictionary carrega; `dictGet` retorna nomes corretos; justificativa escrita.

**Artefatos:** `init/clickhouse/05_dict_institutions.sql`, query de exemplo.

---

## Story 4.4 — Query Grafana sub-segundo (sucesso Pix + delta %)

**Descrição:** A query analítica de destaque — taxa de sucesso Pix por instituição por hora (24h) com comparação ao dia anterior.

**Tarefas:**
- Query: taxa de sucesso de transações **Pix** por instituição por hora nas últimas 24h, com comparação ao mesmo horário do dia anterior (**delta %**).
  - Taxa de sucesso = `countIf(status='settled') / count(*)` por (instituição, hora).
  - Delta %: comparar bucket de hoje com o mesmo bucket de ontem (self-join por hora-do-dia, ou `neighbor`/array functions, ou subquery com `toStartOfHour`).
- **Otimizar para sub-segundo** em centenas de milhões de registros:
  - Servir da **MV/AggregatingMergeTree** quando possível em vez de varrer a tabela raw.
  - Garantir que filtros (`type='pix'`, range de 48h) usem o `ORDER BY`/partição para poda.
  - Usar `LowCardinality` e evitar funções que impeçam uso do índice primário.
- Medir tempo de execução e documentar (`clickhouse-client --time` ou `system.query_log`).

**Critério de aceitação:** query correta com delta % funcional; tempo de execução **sub-segundo** comprovado e documentado; otimização explicada.

**Atenção:** se o volume de teste for menor que "centenas de milhões", documentar o resultado atual + projeção de como escala (e por que o design sustenta sub-segundo).

**Artefatos:** `desafio-1/queries/clickhouse/grafana_pix_success.sql`.

---

## Story 4.5 — API servindo ClickHouse (FastAPI)

**Descrição:** Demonstrar ClickHouse servindo **aplicação** (não só dashboard) via endpoint que retorna JSON.

**Tarefas:**
- Serviço FastAPI em `desafio-1/api/` (a API é tarefa do **Desafio 1 / Parte C**, RF-3.5) com endpoint(s):
  - Ex: `GET /transactions/volume/realtime?window=5m` → volume transacional agregado em tempo real para um painel de operações.
  - Ex: `GET /institutions/{code}/health` → taxa de sucesso/falha recente (alimenta regra de negócio).
- Conexão via `clickhouse-connect`; query parametrizada (evitar SQL injection).
- Retornar JSON estruturado; tratar erros e timeouts.
- Adicionar o serviço ao `docker-compose.yml`.
- Documentar como a aplicação consome (curl de exemplo) e o caso de uso (painel de operações / regra de negócio em tempo real).

**Critério de aceitação:** endpoint sobe no compose; `curl` retorna JSON com dados reais do ClickHouse; latência adequada para tempo real.

**Artefatos:** `desafio-1/api/main.py`, entrada no compose.

---

## Story 4.6 — Carga de dados ClickHouse e validação de performance

**Descrição:** Popular o ClickHouse com volume suficiente para validar as decisões e a query sub-segundo.

**Tarefas:**
- Carregar dados no ClickHouse (via seed direto OU já antecipando o pipeline da Sprint 05):
  - Para esta sprint, um carregamento em massa (CSV/`INSERT SELECT` de uma fonte gerada) é suficiente para validar performance.
  - Idealmente atingir volume alto (100M+) para a query sub-segundo ser convincente; se inviável localmente, documentar a escala usada + projeção.
- Garantir que MVs materializaram (popular histórico se criadas após carga).
- Rodar `OPTIMIZE TABLE transactions FINAL` (ou explicar uso de `FINAL` na leitura) para validar dedup do ReplacingMergeTree.
- Validar performance das queries das stories 4.4 com `system.query_log`.

**Critério de aceitação:** ClickHouse com volume relevante; MVs preenchidas; dedup do ReplacingMergeTree validado; performance medida.

**Atenção:** não confundir o carregamento de validação desta sprint com o **pipeline** da Sprint 05 — aqui é carga estática para testar o schema; lá é sincronização contínua e idempotente.

**Artefatos:** script de carga, evidências de performance no REPORT.

---

## Riscos da Sprint

| Risco | Mitigação |
|---|---|
| MV não popula histórico | Criar MV antes da carga ou `INSERT SELECT` retroativo |
| Query Grafana não fica sub-segundo | Servir de MV; respeitar ORDER BY/partição; medir |
| ReplacingMergeTree retorna duplicatas na leitura | Usar `FINAL` ou `argMax(version)`; explicar trade-off |
| Volume de teste pequeno | Documentar escala + projeção de performance |
| Dictionary não atualiza | Definir `LIFETIME`; pipeline de referência mantém (Sprint 05) |

---

## Saída para a próxima sprint

ClickHouse modelado e validado, pronto para receber o **pipeline contínuo** da Sprint 05. `/compact` preservando: engine/ORDER BY/PARTITION escolhidos, nomes das MVs e do dictionary, a query Grafana e o endpoint da API (todos demonstrados ao vivo).

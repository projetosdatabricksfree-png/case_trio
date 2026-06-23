# Sprint 03 — PostgreSQL Legado & Migração

> **Dia:** 3 · **Peso:** Técnica (40%) + Arquitetura (25%) · **Stories:** 4
> **Cobre:** RF-2.1 a RF-2.3 · **Desafio 1 / Parte B**
> **Objetivo:** Schema legado representativo, queries complexas otimizadas com `EXPLAIN ANALYZE`, e um documento de migração PostgreSQL → Aurora/RDS fundamentado e defensável.

---

## Contexto

A implementação aqui é **leve**, mas o **documento de migração** é onde se demonstra senioridade estratégica — pesa em Arquitetura (25%) e aparece na apresentação (*"Se precisasse migrar o PostgreSQL legado para Aurora amanhã, qual seria seu plano de 72h?"*). Não trate como tarefa secundária.

**Depende de:** Sprint 00 (PostgreSQL legado saudável).
**Habilita:** Sprint 04 (dictionaries usam dados de referência), Sprint 05 (pipeline de referência sincroniza daqui).

---

## Definition of Done da Sprint

- [x] Schema legado (usuários, contas, configurações de instituições parceiras) criado e populado.
- [x] 2+ queries complexas escritas, otimizadas, com `EXPLAIN ANALYZE` antes/depois.
- [x] Índices justificados; ganho mensurável documentado.
- [x] `migration-analysis.md` (1 página) completo: opções, critérios, estratégia zero-downtime, riscos e rollback.

---

## Story 3.1 — Schema legado e seed

**Descrição:** Modelar um legado plausível de referência/configuração e popular com dados sintéticos.

**Tarefas:**
- Tabelas representando o legado transacional de referência:
  - `users`: id, nome, documento, email, status, created_at, etc.
  - `accounts` (legado): id, user_id (FK), institution_code, account_number, type, status, balance, created_at.
  - `institution_configs`: institution_code, institution_name, settlement_window, fee_schedule (jsonb), api_endpoint, active, parâmetros operacionais.
  - (opcional) tabelas auxiliares para enriquecer joins (ex: `institution_partners`, `account_limits`).
- Reusar a **lista de instituições** definida na Sprint 01 (fonte única de verdade — esses dados alimentarão os dictionaries do ClickHouse).
- Seed: dezenas de milhares de usuários/contas; todas as instituições com config.
- Migrations idempotentes em `init/postgres-legado/` ou `desafio-1/schemas/legacy/`.

**Critério de aceitação:** schema criado; dados populados; relacionamentos coerentes (FKs válidas).

**Decisão a registrar:** `institution_configs.institution_name` é a fonte que o dictionary `institution_code → name` do ClickHouse vai consumir.

**Artefatos:** scripts de schema legado + seed Python.

---

## Story 3.2 — Query complexa 1: relatório de contas ativas por instituição

**Descrição:** Query analítica com agregações, otimizada e documentada.

**Tarefas:**
- Relatório de contas ativas por instituição com agregações: contagem de contas ativas, saldo total/médio, distribuição por tipo de conta, por instituição.
- `EXPLAIN ANALYZE` antes (sem índices de apoio).
- Otimizar: índice em `accounts(institution_code, status)`, possivelmente índice parcial `WHERE status = 'active'`. Avaliar índice de cobertura (`INCLUDE`) para evitar heap fetch.
- `EXPLAIN ANALYZE` depois; comparar (Seq Scan → Index Scan, redução de custo, uso de `pg_stat_statements` para corroborar).

**Critério de aceitação:** query correta; ganho documentado com análise do plano.

**Artefatos:** `desafio-1/queries/legacy/report_active_accounts.sql`.

---

## Story 3.3 — Query complexa 2: configurações com joins múltiplos

**Descrição:** Query com joins em múltiplas tabelas, otimizada e documentada.

**Tarefas:**
- Busca de configurações com joins em múltiplas tabelas: ex. usuários + contas + configs de instituição + limites, filtrando por critérios operacionais (instituições ativas com determinada janela de liquidação, contas acima de um limite, etc.).
- `EXPLAIN ANALYZE` antes; identificar o gargalo (join order, hash vs nested loop, falta de índice em FK).
- Otimizar: índices em FKs (`accounts.user_id`, joins por `institution_code`), ajustar para o planner escolher o join adequado.
- `EXPLAIN ANALYZE` depois; comparar.

**Critério de aceitação:** query correta; otimização demonstrada; comentário sobre escolha de join do planner.

**Atenção:** rodar `ANALYZE` após popular e após criar índices, senão o planner decide com estatísticas ruins.

**Artefatos:** `desafio-1/queries/legacy/config_lookup.sql`.

---

## Story 3.4 — Documento de migração PostgreSQL → Aurora/RDS

**Descrição:** Documento de ~1 página com análise e recomendação para evolução do legado. **(Considerar Opus para esta story — é raciocínio de trade-off arquitetural.)**

**Tarefas — cobrir obrigatoriamente:**
- **Opções comparadas:**
  - PostgreSQL on-premise/EC2 (auto-gerenciado).
  - Amazon RDS for PostgreSQL (managed, Multi-AZ).
  - Amazon Aurora PostgreSQL (storage distribuído, failover ~30s, read replicas baratas).
- **Critérios de decisão** (tabela): custo, performance, alta disponibilidade, operational overhead, escalabilidade de leitura, lock-in.
  - Posicionamento defensável: para legado de **referência/configuração** (baixo volume, leitura dominante), **RDS Multi-AZ** já entrega HA com menor custo; Aurora se justifica se houver crescimento, necessidade de múltiplas réplicas de leitura ou Global Database para DR cross-region.
- **Estratégia de migração com zero/mínimo downtime:**
  - **Replicação lógica nativa** (publication/subscription) como caminho preferencial para minimizar downtime.
  - **AWS DMS** como alternativa (CDC contínuo), citando limitações (tipos exóticos, sequências, ausência de algumas constraints na cópia).
  - **Blue-green** (RDS Blue/Green Deployments) para cutover controlado.
  - Cutover: validação de paridade de dados em paralelo → swap de connection string/DNS → janela de reconciliação.
- **Riscos e plano de rollback:**
  - Riscos: divergência de dados, diferença de versão/extensões, performance pós-cutover, falha de replicação.
  - Rollback: manter origem ativa em modo leitura até validação; reverter connection string; replicação reversa se necessário.

**Critério de aceitação:** documento de ~1 página, estruturado, com recomendação justificada e plano de migração + rollback concretos.

**Artefatos:** `desafio-1/migration-analysis.md`.

---

## Riscos da Sprint

| Risco | Mitigação |
|---|---|
| Tratar migração como afterthought | Reservar tempo real; é peça de Arquitetura (25%) |
| Query "complexa" trivial demais | Garantir joins múltiplos + agregações reais |
| Recomendação genérica ("use Aurora") | Posicionar com critérios e contexto do legado (baixo volume) |
| Esquecer `ANALYZE` pós-índice | Planner decide errado; rodar sempre |

---

## Saída para a próxima sprint

O legado está pronto e a fonte de dados de referência (institution_configs) disponível para alimentar os dictionaries do ClickHouse. `/compact` preservando: schema legado, decisão de fonte única de instituições, e a recomendação de migração (citada no ADR da Sprint 05 e na apresentação).

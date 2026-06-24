# Sprint 06 — Operação & Observabilidade

> **Dias:** 5–6 · **Peso:** Operação e Resiliência (20%) · **Stories:** 6
> **Cobre:** RF-5.1 a RF-5.5 · **Desafio 3 (Partes A e B)**
> **Objetivo:** Backup funcional dos 3 bancos, recovery demonstrado, runbook do storage em 92%, dashboards Grafana dos 4 alvos, e 5+ alertas críticos definidos com integração AWS.

---

## Contexto

Em infraestrutura de pagamentos, *"a capacidade de operar, diagnosticar e recuperar sob pressão é tão importante quanto construir"*. Esta sprint demonstra maturidade operacional — backup que **realmente roda**, recovery **realmente testado**, e o runbook do storage em 92% (que envolve as nuances de chunks comprimidos vistas na Sprint 02).

**Depende de:** todas as sprints de dados (01–05).
**Habilita:** Sprint 07 (a resposta ao incidente referencia dashboards e runbooks daqui).

---

## Definition of Done da Sprint

- [x] Backup funcional implementado para TimescaleDB, PostgreSQL e ClickHouse (script roda).
- [x] Recovery demonstrado com timestamps e validação de contagem (antes/perda/depois).
- [x] Runbook do storage em 92% completo (pré-requisitos, comandos, checkpoints, rollback, comunicação).
- [x] 4 dashboards Grafana funcionais (TimescaleDB, ClickHouse, Pipeline, PostgreSQL legado).
- [x] 5+ alertas críticos definidos (métrica, threshold, severidade, ação, integração CloudWatch/SNS).
- [x] Pelo menos um dashboard comprovadamente consultando ClickHouse (critério mínimo do desafio).

---

## Story 6.1 — Estratégia e scripts de backup (3 bancos)

**Descrição:** Implementar backup funcional para cada banco, definindo tipo, frequência, retenção e destino AWS.

**Tarefas — por banco:**
- **TimescaleDB:**
  - Tipo: backup **lógico** (`pg_dump`) — adequado por ser managed no Timescale Cloud; mencionar que físico/contínuo via WAL existe mas o managed abstrai.
  - Considerar backup consciente de hypertable/CAggs.
  - Script funcional que gera dump e (em produção) envia para S3.
- **PostgreSQL legado:**
  - Tipo: `pg_dump` full lógico + menção a `pg_basebackup` + WAL archiving para point-in-time recovery.
  - Script funcional.
- **ClickHouse:**
  - Tipo: `BACKUP TABLE ... TO Disk(...)` nativo (v22.4+) ou `clickhouse-backup`.
  - Script funcional gerando backup das tabelas e MVs.
- **Para todos, definir e documentar:**
  - Frequência (ex: full diário + incremental/WAL conforme banco) e retenção.
  - **Destino AWS em produção:** S3 com **lifecycle policies** (transição para Glacier após N dias), **cross-region** para DR, versionamento, criptografia (SSE-KMS).
- Script orquestrador em `desafio-3/backup/` que roda os três e loga resultado.

**Critério de aceitação:** `bash desafio-3/backup/run_backups.sh` (ou equivalente) gera artefatos de backup dos 3 bancos sem erro; estratégia AWS documentada.

**Artefatos:** `desafio-3/backup/backup_timescaledb.sh`, `backup_postgres.sh`, `backup_clickhouse.sh`, `run_backups.sh`, `README` do backup.

---

## Story 6.2 — Procedimento de recovery (demonstrado)

**Descrição:** Simular perda de dados e restaurar a partir do backup, com validação rigorosa.

**Tarefas:**
- Escolher um banco (TimescaleDB é o mais ilustrativo) e executar o ciclo documentado:
  1. **Contagem antes:** `SELECT count(*) FROM transactions WHERE created_at BETWEEN ...` — registrar com timestamp.
  2. **Simular perda:** `DELETE` de transações em um período específico — registrar contagem após perda.
  3. **Recovery:** restaurar a partir do backup (restore do dump, ou restore seletivo do período).
  4. **Contagem depois:** validar que a contagem voltou ao estado original.
- Documentar **passo a passo com timestamps** e validações (antes / após perda / após recovery).
- Discutir RTO/RPO observados e como melhorariam em produção (PITR via WAL, snapshots automáticos do RDS/Aurora).

**Critério de aceitação:** ciclo perda→recovery documentado com contagens e timestamps; dados restaurados validados.

**Artefatos:** `desafio-3/backup/recovery-demo.md`.

---

## Story 6.3 — Runbook: storage Timescale Cloud em 92%

**Descrição:** Runbook operacional para sanitizar e remover chunks antigos sem downtime nem perda de agregados. **(Considerar Opus — é o runbook mais nuançado.)**

**Tarefas — o runbook deve conter:**
- **Cenário:** storage em 92%; chunks comprimidos de 6+ meses precisam ser sanitizados e removidos sem downtime e sem perder dados agregados nos continuous aggregates.
- **Pré-requisitos e validações antes de começar:**
  - Confirmar que os CAggs já materializaram o período-alvo (`SELECT` de sanidade nos CAggs antes de tocar a raw).
  - Confirmar retenção dos CAggs (2 anos) > período a remover da raw.
  - Snapshot/backup recente antes da operação.
  - Verificar jobs de compressão/retenção ativos.
- **Passo a passo com comandos SQL:**
  - Identificar chunks-alvo: `SELECT show_chunks('transactions', older_than => INTERVAL '6 months');`
  - Validar que estão comprimidos e já agregados.
  - Remover: `SELECT drop_chunks('transactions', older_than => INTERVAL '6 months');` (libera storage; CAggs preservam os agregados).
  - Se houver PII a sanitizar antes de descartar e a regra exigir trilha: aplicar o procedimento LGPD (descomprimir→sanitizar→registrar) onde aplicável.
- **Checkpoints de validação:** storage antes/depois (`hypertable_size`, `pg_database_size`), contagem de chunks, integridade dos CAggs.
- **Plano de rollback:** restaurar do backup se a remoção foi além do previsto; como reconstruir um CAgg se necessário.
- **Comunicação para stakeholders:** template de aviso (início, progresso, conclusão) para Data Champions e liderança.

**Critério de aceitação:** runbook completo, executável, com comandos reais, checkpoints e rollback; aborda explicitamente a preservação dos CAggs.

**Artefatos:** `desafio-3/runbook.md`.

---

## Story 6.4 — Dashboards Grafana: TimescaleDB + Pipeline

**Descrição:** Provisionar dashboards para TimescaleDB e Pipeline.

**Tarefas:**
- Datasources já vêm provisionados na foundation (`desafio-3/grafana/provisioning/datasources/`, montado pelo compose); aqui o foco são os **dashboards**.
- **Dashboard TimescaleDB:** conexões ativas, queries lentas, saúde dos chunks, jobs de compressão/retenção, tamanho por hypertable, status dos continuous aggregates. (Fontes: `pg_stat_activity`, `timescaledb_information.jobs`, `chunk_compression_stats`, `hypertable_size`.)
- **Dashboard de Pipeline:** lag de sincronização, throughput de eventos, erros, última execução com sucesso. (Fonte: métricas expostas pelo pipeline da Sprint 05.)
- Provisionar dashboards como JSON versionado (não só criados na UI) em `desafio-3/grafana/provisioning/dashboards/`, com o provider correspondente, para subir junto com o compose.

**Critério de aceitação:** ambos os dashboards carregam com dados reais; provisionamento versionado.

**Artefatos:** `desafio-3/grafana/provisioning/dashboards/timescaledb.json`, `pipeline.json` (+ provider yaml).

---

## Story 6.5 — Dashboards Grafana: ClickHouse + PostgreSQL legado

**Descrição:** Provisionar dashboards para ClickHouse e PostgreSQL legado.

**Tarefas:**
- **Dashboard ClickHouse:** queries em execução, memória consumida, merges em andamento, inserções/segundo, tamanho de partições, latency de queries das aplicações. (Fontes: `system.processes`, `system.merges`, `system.parts`, `system.query_log`, `system.metrics`.)
- **Dashboard PostgreSQL legado:** conexões, queries lentas (`pg_stat_statements`), bloat estimado. **Incluir métricas que ajudariam a justificar a migração para Aurora** (ex: tempo de query crescente, conexões saturando, overhead de manutenção — amarrar ao `migration-analysis.md` da Sprint 03).
- Garantir o **critério mínimo do desafio:** pelo menos um dashboard consultando ClickHouse está funcional.

**Critério de aceitação:** ambos os dashboards carregam; dashboard ClickHouse comprovadamente funcional; métricas pró-migração presentes no de PostgreSQL.

**Atenção:** habilitar `pg_stat_statements` no PostgreSQL legado (extensão + `shared_preload_libraries`) — ajustar na Sprint 00/03 se ainda não feito.

**Artefatos:** `desafio-3/grafana/provisioning/dashboards/clickhouse.json`, `postgres-legacy.json`.

---

## Story 6.6 — Alertas críticos (5+) e integração AWS

**Descrição:** Definir os alertas de produção e como integrariam com CloudWatch/SNS.

**Tarefas:**
- Definir **pelo menos 5 alertas críticos**. Para cada um: **métrica, threshold, severidade, ação esperada, integração CloudWatch/SNS**. Sugestões:
  1. **Pipeline lag** > X min → SEV-2 → investigar pipeline; SNS → on-call.
  2. **Volume transacional = 0** por > N min (em horário comercial) → SEV-1 → war room (este é exatamente o incidente da Sprint 07).
  3. **Storage TimescaleDB** > 85% → SEV-2 → acionar runbook de chunks.
  4. **ClickHouse memória/merges** acima do limite / fila de merges crescente → SEV-2.
  5. **Conexões PostgreSQL** saturando (perto do `max_connections`) → SEV-2.
  6. **Taxa de falha de transações** acima do baseline → SEV-1/2 (sinal de problema sistêmico).
  7. **Última execução de backup** falhou ou não ocorreu na janela → SEV-2.
- **Integração AWS:** descrever o caminho métrica → CloudWatch (custom metrics / agent) → CloudWatch Alarm → SNS topic → PagerDuty/Slack/email. Mencionar como alertas do Grafana podem usar contact points e como conviveriam com CloudWatch Alarms.
- Documentar a matriz de severidade e a ação esperada por alerta.

**Critério de aceitação:** ≥ 5 alertas documentados com os 5 atributos cada; caminho de integração AWS descrito; pelo menos um alerta efetivamente configurado no Grafana como prova de conceito.

**Artefatos:** `desafio-3/alerts.md`, alertas provisionados em `desafio-3/grafana/provisioning/alerting/` (PoC).

---

## Riscos da Sprint

| Risco | Mitigação |
|---|---|
| Backup que "documenta" mas não roda | Scripts executáveis; validar saída real |
| Recovery sem validação de contagem | Registrar antes/perda/depois com timestamps |
| Runbook ignora preservação de CAggs | Story 6.3 valida CAggs antes de `drop_chunks` |
| Dashboards só na UI (não reproduzíveis) | Provisionar como JSON versionado |
| `pg_stat_statements` não habilitado | Habilitar via `shared_preload_libraries` |

---

## Saída para a próxima sprint

Camada operacional pronta. A Sprint 07 usa estes dashboards, runbooks e alertas como base para a resposta ao incidente SEV-1 e para o empacotamento final. `/compact` preservando: estratégia de backup, demo de recovery, runbook de storage, dashboards provisionados e a lista de alertas (todos referenciados na apresentação).

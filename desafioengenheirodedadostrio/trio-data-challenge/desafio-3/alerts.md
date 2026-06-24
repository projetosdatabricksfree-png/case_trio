# Alertas Críticos & Integração AWS — Desafio 3 · Sprint 06

Catálogo dos **7 alertas críticos** da plataforma (métrica · threshold · severidade ·
ação · integração) + matriz de severidade + caminho de integração com CloudWatch/SNS.
Um deles está **provisionado como PoC** no Grafana (ver §4).

## 1. Catálogo de alertas

| # | Alerta | Métrica / fonte | Threshold | Sev | Ação esperada | Integração CloudWatch/SNS |
|---|---|---|---|:---:|---|---|
| 1 | **Pipeline lag alto** | `pipeline_runs.lag_seconds` (ClickHouse) | > **5 min** (300s) por 5 min | SEV-2 | Investigar pipeline (origem lenta? CH down?); ver `desafio-2/README.md` | métrica custom → CloudWatch Alarm → SNS `trio-oncall` → PagerDuty |
| 2 | **Volume transacional = 0** | `count()` em `transactions` na janela (CH) | **0** por > 10 min em horário comercial | **SEV-1** | War room — é o incidente da Sprint 07 (ingestão parada) | Alarm `treatMissingData=breaching` → SNS SEV-1 → PagerDuty + Slack |
| 3 | **Storage TimescaleDB alto** | `hypertable_size` / disco (TS) | > **85%** | SEV-2 | Acionar o **runbook de chunks** (`runbook.md`) | CloudWatch `FreeStorageSpace` (RDS) / custom → Alarm → SNS |
| 4 | **ClickHouse memória/merges** | `system.metrics.MemoryTracking`, fila de `system.merges` | memória > 80% **ou** merges crescendo sem drenar | SEV-2 | Throttle de inserts; revisar partições/TTL; escalar nó | métrica custom → Alarm → SNS |
| 5 | **Conexões Postgres saturando** | `pg_stat_activity` / `max_connections` (legado) | > **85%** do `max_connections` | SEV-2 | Pooler (PgBouncer); investigar conexões presas; gatilho pró-Aurora | RDS `DatabaseConnections` → Alarm → SNS |
| 6 | **Taxa de falha de transações** | `status='failed'` / total (CH/MV funnel) | acima do **baseline + Nσ** | SEV-1 | Problema sistêmico (instituição/rota); acionar squad de pagamentos | métrica custom → Alarm anômalo → SNS SEV-1 |
| 7 | **Backup falhou / atrasado** | saída de `run_backups.sh` / idade do último artefato | falha **ou** sem backup na janela diária | SEV-2 | Re-rodar backup; investigar destino S3/credenciais | EventBridge (job) / Lambda check → Alarm → SNS |

> Limiares são pontos de partida defensáveis; em produção calibram-se com baseline
> histórico (CloudWatch Anomaly Detection para os de taxa/volume).

## 2. Matriz de severidade

| Sev | Significado | Resposta | Notificação |
|---|---|---|---|
| **SEV-1** | Impacto a clientes / receita; ingestão ou pagamentos parados | War room imediato, on-call paginado 24/7 | PagerDuty (page) + Slack `#sev1` + e-mail liderança |
| **SEV-2** | Degradação / risco iminente sem impacto a cliente ainda | On-call no horário, mitigação em horas | PagerDuty (notify) + Slack `#alerts` |
| **SEV-3** | Anomalia a observar; sem urgência | Ticket, tratar no próximo ciclo | Slack `#alerts` |

## 3. Integração AWS (caminho métrica → alerta)

```
[ origem da métrica ]                         [ alerta ]                 [ notificação ]
TimescaleDB / Postgres ─ CloudWatch Agent ─┐
ClickHouse (system.*) ── custom metric  ───┼─► CloudWatch  ─► CloudWatch  ─► SNS topic ─► PagerDuty
Pipeline (logs JSON) ─── EMF / custom    ──┘     Metrics        Alarm        (por sev)     Slack / e-mail
                                                                                │
RDS/Aurora (nativas: FreeStorageSpace, DatabaseConnections, CPUUtilization) ───┘
```

- **Coleta:** CloudWatch Agent (Postgres/host), **custom metrics** via `PutMetricData` ou
  **EMF** (Embedded Metric Format) a partir dos logs JSON do pipeline; métricas nativas do
  RDS/Aurora já chegam ao CloudWatch.
- **Avaliação:** **CloudWatch Alarms** (estático ou **Anomaly Detection**) com
  `treatMissingData` adequado (ex.: `breaching` para o alerta de volume=0).
- **Roteamento:** Alarm → **SNS topic por severidade** → assinantes **PagerDuty** (page),
  **Slack** (chatbot), **e-mail**. EventBridge para automações (ex.: disparar um runbook
  Lambda no alerta de storage).
- **IAM least-privilege** em cada hop; runbook linkado em cada alarme (campo `runbook`).

### Grafana × CloudWatch (convivência)
O Grafana entra como **camada de visualização e alertas de aplicação** (lê ClickHouse,
TimescaleDB, Postgres direto) com **contact points** próprios (webhook → SNS/PagerDuty/Slack).
O **CloudWatch Alarms** cobre a **infra gerenciada** (RDS/Aurora/EC2/EBS) e métricas de
plataforma. Ambos publicam no **mesmo SNS topic por severidade**, então o on-call recebe um
fluxo unificado independentemente da origem. Evita-se duplicidade definindo cada alerta numa
única fonte (app→Grafana, infra→CloudWatch).

## 4. PoC provisionada no Grafana

Provisionada em `grafana/provisioning/alerting/alerts.yml` (versionada, sobe com o compose):

- **Contact point** `trio-oncall` (webhook placeholder → em produção, SNS/PagerDuty).
- **Regra** `Pipeline lag alto (SEV-2)`: lê `trio_analytics.pipeline_runs` no ClickHouse,
  `reduce(last)` → `math $B > 300`, `for: 5m`, label `severity=sev2`.
- **Comportamento:** **verde** em operação normal (lag = 0); vira **firing** se o pipeline
  atrasar > 5 min — demonstrável parando o serviço `pipeline` e avançando a origem.

```bash
# Verificar a regra provisionada:
curl -s -u admin:admin http://localhost:3000/api/v1/provisioning/alert-rules | jq '.[].title'
# Estado da regra (inactive = normal):
curl -s -u admin:admin http://localhost:3000/api/prometheus/grafana/api/v1/rules
```

> O alerta de **volume = 0** (#2) é o gatilho exato do incidente **SEV-1 da Sprint 07** —
> documentado aqui e referenciado lá.

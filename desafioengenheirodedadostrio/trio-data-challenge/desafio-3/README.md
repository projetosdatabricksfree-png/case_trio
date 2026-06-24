# Desafio 3 — Operação, Resiliência e Observabilidade

Backup/recovery, observabilidade (Grafana) e resposta a incidentes.

| Pasta / arquivo | Conteúdo | Preenchido em |
|---|---|---|
| `backup/` | Scripts de backup dos 3 bancos + demo de recovery + estratégia AWS | ✅ Sprint 06 |
| `runbook.md` | Runbook de storage (chunks 92%, preserva CAggs, rollback, comunicação) | ✅ Sprint 06 |
| `runbook-storage-check.sql` | Validação READ-ONLY do runbook (`make runbook-storage-check`) | ✅ Sprint 06 |
| `alerts.md` | 7 alertas críticos + matriz de severidade + integração CloudWatch/SNS | ✅ Sprint 06 |
| `clickhouse/config.d/backup_disk.xml` | Disco de backup nativo do ClickHouse (`BACKUP TO Disk`) | ✅ Sprint 06 |
| `grafana/provisioning/datasources/` | 3 datasources (uid explícito) | ✅ Sprint 00/06 |
| `grafana/provisioning/dashboards/` | 4 dashboards (TimescaleDB, Pipeline, ClickHouse, Postgres legado) | ✅ Sprint 06 |
| `grafana/provisioning/alerting/` | Contact point + regra PoC (pipeline lag SEV-2) | ✅ Sprint 06 |
| `incident-response.md` | Resposta a incidente SEV-1 | Sprint 07 |

> `grafana/provisioning/` é montado pelo `docker-compose.yml` em `/etc/grafana/provisioning`.

## Backup & Recovery

```bash
make backup            # backup dos 3 bancos -> backup/artifacts/ (gitignored)
make recovery-demo     # ciclo perda -> recovery validado (antes == depois)
```

- TimescaleDB e Postgres legado: `pg_dump -Fc` (lógico).
- ClickHouse: `BACKUP ... TO Disk('backups')` nativo (disco em `clickhouse/config.d/`).
- Estratégia, frequência, retenção e destino AWS (S3 + lifecycle/Glacier, cross-region,
  SSE-KMS) em [`backup/README.md`](backup/README.md). Recovery validado com timestamps em
  [`backup/recovery-demo.md`](backup/recovery-demo.md).

## Observabilidade (Grafana — http://localhost:3000, admin/admin)

4 dashboards provisionados na pasta **Trio** (JSON versionado, sobem com o compose):

| Dashboard | Datasource | Destaques |
|---|---|---|
| **TimescaleDB** | postgres | conexões, jobs de compressão/retenção, tamanho/chunks, CAggs |
| **Pipeline (TS → CH)** | ClickHouse | lag, throughput, DLQ, última run OK (lê `pipeline_runs`) |
| **ClickHouse** | ClickHouse | queries, merges, memória, partições, latência |
| **PostgreSQL Legado** | postgres | conexões, queries lentas, bloat + **sinais pró-migração** |

≥ 2 dashboards consultam o **ClickHouse** (critério mínimo do desafio). Alertas em
[`alerts.md`](alerts.md) (PoC provisionada: pipeline lag SEV-2).

## Storage runbook

Cenário "storage em 92%" — remover chunks antigos sem downtime e **sem perder os CAggs**:
[`runbook.md`](runbook.md). Validação read-only segura ao vivo:
`make runbook-storage-check`.

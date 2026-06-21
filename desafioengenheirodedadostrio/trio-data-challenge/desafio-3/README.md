# Desafio 3 — Operação, Resiliência e Observabilidade

Backup/recovery, observabilidade (Grafana) e resposta a incidentes.

| Pasta / arquivo | Conteúdo | Preenchido em |
|---|---|---|
| `backup/` | Scripts e artefatos de backup/restore | Sprint 06 |
| `grafana/provisioning/` | Datasources (✅ Sprint 00) + dashboards/alertas | Sprints 00, 06 |
| `runbook.md` | Runbook operacional (storage, recovery, rotinas) | Sprint 06 |
| `incident-response.md` | Resposta a incidente SEV-1 | Sprint 07 |

> `grafana/provisioning/` é montado pelo `docker-compose.yml` em `/etc/grafana/provisioning`.
> Os datasources dos 3 bancos já estão provisionados desde a Sprint 00.

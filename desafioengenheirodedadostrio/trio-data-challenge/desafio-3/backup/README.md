# Backup & Recovery — Desafio 3 · Sprint 06

Backup **funcional** dos 3 bancos + demo de recovery validada. Scripts executáveis,
artefatos versionados **fora** do git (`artifacts/` é gitignored). Reutilizados pelo CI.

## Scripts

| Script | Banco | Tipo | Artefato |
|---|---|---|---|
| `backup_timescaledb.sh` | TimescaleDB (`trio_transactions`) | `pg_dump -Fc` (lógico, hypertable-aware) | `artifacts/timescaledb_<ts>.dump` |
| `backup_postgres.sh` | PostgreSQL legado (`trio_legado`) | `pg_dump -Fc` (lógico full) | `artifacts/postgres_legado_<ts>.dump` |
| `backup_clickhouse.sh` | ClickHouse (`trio_analytics`) | `BACKUP ... TO Disk` (nativo) | `artifacts/trio_analytics_<ts>.zip` |
| `run_backups.sh` | os 3 | orquestra + valida + sumário | — |
| `recovery-demo.sh` | TimescaleDB | perda → restore staging → recovery seletivo | — |

```bash
make backup            # roda os 3 backups (artefatos em artifacts/)
make recovery-demo     # ciclo perda -> recovery validado (antes == depois)
```

## Estratégia por banco

### TimescaleDB — `pg_dump -Fc`
Backup **lógico** (custom format). `pg_dump` é hypertable-aware: serializa os chunks
(inclusive comprimidos) e os objetos do TimescaleDB. O restore exige o procedimento
oficial `timescaledb_pre_restore()` / `timescaledb_post_restore()` (ver `recovery-demo.sh`).
- **Frequência:** full diário.
- **Produção:** o Timescale Cloud abstrai backup contínuo (snapshots + WAL/PITR
  gerenciados); o dump lógico complementa para portabilidade e DR cross-region em S3.

### PostgreSQL legado — `pg_dump -Fc`
Banco de **referência/config** (baixo volume, leitura-dominante): dump lógico full é
suficiente.
- **Frequência:** full diário.
- **Produção:** `pg_basebackup` + **WAL archiving** habilita **PITR** (recuperação a
  qualquer ponto no tempo); RDS/Aurora entregam snapshots automáticos + PITR gerenciados.

### ClickHouse — `BACKUP ... TO Disk` nativo
Comando nativo (CH 22.4+) sobre o disco `backups`
(`config.d/backup_disk.xml`). Cobre a base mutável (`transactions`), as MVs
(`tx_daily_summary`, `tx_status_funnel`) e as tabelas de controle/referência. O artefato
nasce no volume do CH e é copiado para o host via `docker compose cp`.
- **Frequência:** full diário + (produção) incremental via `clickhouse-backup`.
- **Produção:** `BACKUP ... TO S3(...)` direto, ou `clickhouse-backup` (incremental,
  upload S3, lifecycle).

## Destino & retenção em produção (AWS)

| Aspecto | Decisão |
|---|---|
| **Destino** | **S3** (bucket dedicado por ambiente) |
| **Lifecycle** | transição para **Glacier/Deep Archive** após N dias; expiração após o período de retenção |
| **DR** | replicação **cross-region** (CRR) do bucket para uma região secundária |
| **Versionamento** | habilitado (protege contra overwrite/delete acidental) |
| **Criptografia** | **SSE-KMS** (chave gerenciada, rotação + trilha de auditoria) |
| **Acesso** | IAM least-privilege (role de backup só com `s3:PutObject` no prefixo) |
| **Retenção** | full diário 30d; semanal 90d; mensal 1 ano (ajustável por compliance) |

Localmente, `run_backups.sh` poda artefatos com mais de `BACKUP_RETENTION_DAYS` dias
(default 7) — o equivalente didático ao lifecycle do S3.

## Recovery

Ciclo demonstrado e validado em [`recovery-demo.md`](recovery-demo.md): contagem
**antes → perda → depois** com timestamps, RTO/RPO observados e o caminho de produção
(PITR via WAL, snapshots RDS/Aurora). A remoção de chunks antigos para liberar storage
(cenário "92%") tem runbook próprio em [`../runbook.md`](../runbook.md).

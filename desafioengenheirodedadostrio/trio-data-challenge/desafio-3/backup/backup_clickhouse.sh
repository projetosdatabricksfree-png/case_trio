#!/usr/bin/env bash
# =============================================================================
#  Trio Data Challenge — Backup do ClickHouse (Sprint 06 · Story 6.1)
#  Backup NATIVO via `BACKUP TABLE ... TO Disk('backups', ...)` (CH 22.4+).
#  Cobre a base mutável (transactions), as MVs e as tabelas de controle/ref.
#  O disco 'backups' é habilitado por desafio-3/clickhouse/config.d/backup_disk.xml.
#  O artefato nasce dentro do volume do CH e é copiado para o host (docker cp).
#  Uso:   ./backup_clickhouse.sh        (ou via run_backups.sh / make backup)
#  Saída: 0 = BACKUP_CREATED e artefato copiado | 1 = falhou.
#  PRODUÇÃO: trocar Disk('backups') por S3(...) + clickhouse-backup incremental.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/../.."

if [[ -f .env ]]; then
  set -a
  # shellcheck source=/dev/null
  . ./.env
  set +a
fi
CLICKHOUSE_USER="${CLICKHOUSE_USER:-trio}"
CLICKHOUSE_PASSWORD="${CLICKHOUSE_PASSWORD:-trio2024}"
ARTIFACTS_DIR="${BACKUP_DIR:-$SCRIPT_DIR/artifacts}"
mkdir -p "$ARTIFACTS_DIR"

ts="$(date -u +%Y%m%dT%H%M%SZ)"
name="trio_analytics_${ts}.zip"

CH() { docker compose exec -T clickhouse clickhouse-client \
  --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" -d trio_analytics "$@"; }

echo "== Backup ClickHouse (trio_analytics) -> BACKUP ... TO Disk('backups') =="

# BACKUP é síncrono por padrão: retorna "<uuid>\t<status>".
result="$(CH -q "
  BACKUP
    TABLE trio_analytics.transactions,
    TABLE trio_analytics.tx_daily_summary,
    TABLE trio_analytics.tx_status_funnel,
    TABLE trio_analytics.pipeline_runs,
    TABLE trio_analytics.ref_institutions
  TO Disk('backups', '${name}')
  FORMAT TSV")"
status="$(printf '%s' "$result" | tail -n1 | cut -f2)"
echo "  status: ${status:-<vazio>}"

if [[ "$status" != "BACKUP_CREATED" ]]; then
  echo "FALHOU: BACKUP não chegou a BACKUP_CREATED"; exit 1
fi

# Copia o artefato (arquivo dentro do volume do CH) para o host.
out="$ARTIFACTS_DIR/$name"
docker compose cp "clickhouse:/var/lib/clickhouse/backups/${name}" "$out"

if [[ -s "$out" ]]; then
  printf 'OK: ClickHouse -> %s (%s)\n' "$out" "$(du -h "$out" | cut -f1)"
  exit 0
fi
echo "FALHOU: artefato não copiado para o host ($out)"; exit 1

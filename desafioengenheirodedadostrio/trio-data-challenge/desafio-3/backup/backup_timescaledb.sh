#!/usr/bin/env bash
# =============================================================================
#  Trio Data Challenge — Backup do TimescaleDB (Sprint 06 · Story 6.1)
#  Backup LÓGICO via pg_dump -Fc (custom format) do banco trio_transactions.
#  pg_dump é hypertable-aware: serializa os chunks (inclusive comprimidos) e os
#  objetos do TimescaleDB. Restore exige timescaledb_pre_restore/post_restore
#  (ver desafio-3/backup/recovery-demo.sh).
#  Uso:   ./backup_timescaledb.sh        (ou via run_backups.sh / make backup)
#  Saída: 0 = artefato gerado | 1 = falhou. Artefato em backup/artifacts/.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/../.."   # raiz do compose (desafioengenheirodedadostrio/trio-data-challenge)

if [[ -f .env ]]; then
  set -a
  # shellcheck source=/dev/null
  . ./.env
  set +a
fi
POSTGRES_USER="${POSTGRES_USER:-trio}"
ARTIFACTS_DIR="${BACKUP_DIR:-$SCRIPT_DIR/artifacts}"
mkdir -p "$ARTIFACTS_DIR"

ts="$(date -u +%Y%m%dT%H%M%SZ)"
out="$ARTIFACTS_DIR/timescaledb_${ts}.dump"

echo "== Backup TimescaleDB (trio_transactions) -> pg_dump -Fc =="
docker compose exec -T timescaledb \
  pg_dump -U "$POSTGRES_USER" -d trio_transactions -Fc --no-owner > "$out"

if [[ -s "$out" ]]; then
  printf 'OK: TimescaleDB -> %s (%s)\n' "$out" "$(du -h "$out" | cut -f1)"
  exit 0
fi
echo "FALHOU: dump vazio ($out)"; rm -f "$out"; exit 1

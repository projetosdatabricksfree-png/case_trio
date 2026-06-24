#!/usr/bin/env bash
# =============================================================================
#  Trio Data Challenge — Backup do PostgreSQL legado (Sprint 06 · Story 6.1)
#  Backup LÓGICO full via pg_dump -Fc do banco trio_legado (referência/config).
#  Banco pequeno e leitura-dominante: dump lógico é suficiente. Em produção,
#  complementar com pg_basebackup + WAL archiving para PITR (ver README.md).
#  Uso:   ./backup_postgres.sh          (ou via run_backups.sh / make backup)
#  Saída: 0 = artefato gerado | 1 = falhou. Artefato em backup/artifacts/.
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
POSTGRES_USER="${POSTGRES_USER:-trio}"
ARTIFACTS_DIR="${BACKUP_DIR:-$SCRIPT_DIR/artifacts}"
mkdir -p "$ARTIFACTS_DIR"

ts="$(date -u +%Y%m%dT%H%M%SZ)"
out="$ARTIFACTS_DIR/postgres_legado_${ts}.dump"

echo "== Backup PostgreSQL legado (trio_legado) -> pg_dump -Fc =="
docker compose exec -T postgres-legado \
  pg_dump -U "$POSTGRES_USER" -d trio_legado -Fc --no-owner > "$out"

if [[ -s "$out" ]]; then
  printf 'OK: PostgreSQL legado -> %s (%s)\n' "$out" "$(du -h "$out" | cut -f1)"
  exit 0
fi
echo "FALHOU: dump vazio ($out)"; rm -f "$out"; exit 1

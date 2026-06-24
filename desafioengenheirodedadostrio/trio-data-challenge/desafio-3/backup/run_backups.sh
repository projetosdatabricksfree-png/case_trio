#!/usr/bin/env bash
# =============================================================================
#  Trio Data Challenge — Orquestrador de backup dos 3 bancos (Sprint 06 · 6.1)
#  Roda os backups de TimescaleDB, PostgreSQL legado e ClickHouse, valida os
#  artefatos e imprime um sumário. Reutilizado pelo CI.
#  Uso:   ./run_backups.sh   (ou: make backup)
#  Saída: 0 = os 3 backups OK | 1 = algum falhou.
#  Retenção: poda artefatos com mais de BACKUP_RETENTION_DAYS dias (default 7).
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
ARTIFACTS_DIR="${BACKUP_DIR:-$SCRIPT_DIR/artifacts}"
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-7}"

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  GREEN=$'\e[32m'; RED=$'\e[31m'; BOLD=$'\e[1m'; RESET=$'\e[0m'
else
  GREEN=''; RED=''; BOLD=''; RESET=''
fi

printf "%sTrio Data Challenge — backup dos 3 bancos%s\n" "$BOLD" "$RESET"
printf "Destino: %s · retenção: %s dias\n\n" "$ARTIFACTS_DIR" "$RETENTION_DAYS"

fails=0
run() {  # run <label> <script>
  printf "%s» %s%s\n" "$BOLD" "$1" "$RESET"
  if "$SCRIPT_DIR/$2"; then
    printf "  %s✔%s %s\n\n" "$GREEN" "$RESET" "$1"
  else
    printf "  %s✗%s %s\n\n" "$RED" "$RESET" "$1"; fails=$((fails + 1))
  fi
}

run "TimescaleDB" backup_timescaledb.sh
run "PostgreSQL legado" backup_postgres.sh
run "ClickHouse" backup_clickhouse.sh

# Retenção: remove artefatos antigos (produção faria via lifecycle do S3).
if [[ -d "$ARTIFACTS_DIR" ]]; then
  find "$ARTIFACTS_DIR" -maxdepth 1 -type f \( -name '*.dump' -o -name '*.zip' \) \
    -mtime "+$RETENTION_DAYS" -print -delete | sed 's/^/  podado: /' || true
fi

printf "%sArtefatos atuais:%s\n" "$BOLD" "$RESET"
ls -lh "$ARTIFACTS_DIR" 2>/dev/null | tail -n +2 | sed 's/^/  /' || true

printf "\n"
if [[ "$fails" -eq 0 ]]; then
  printf "%s✔ BACKUP OK — os 3 bancos%s\n" "$BOLD$GREEN" "$RESET"
  exit 0
fi
printf "%s✗ BACKUP FALHOU — %d banco(s) com erro%s\n" "$BOLD$RED" "$fails" "$RESET"
exit 1

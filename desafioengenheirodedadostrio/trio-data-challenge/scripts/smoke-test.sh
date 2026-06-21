#!/usr/bin/env bash
# =============================================================================
#  Trio Data Challenge — Smoke Test
#  Valida que os 4 serviços subiram e estão saudáveis.
#  Uso:   ./scripts/smoke-test.sh   (ou: make smoke)
#  Saída: 0 = tudo ok | 1 = alguma verificação falhou.
#  Reutilizado pelo CI (.github/workflows/ci.yml, job integration).
# =============================================================================
set -euo pipefail

# Diretório do compose = pai de scripts/ — permite rodar de qualquer lugar.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

# Credenciais: .env quando existir, senão defaults de desenvolvimento.
if [[ -f .env ]]; then
  set -a; . ./.env; set +a
fi
POSTGRES_USER="${POSTGRES_USER:-trio}"
CLICKHOUSE_USER="${CLICKHOUSE_USER:-trio}"
CLICKHOUSE_PASSWORD="${CLICKHOUSE_PASSWORD:-trio2024}"
GRAFANA_URL="${GRAFANA_URL:-http://localhost:3000}"

# Cores apenas em TTY e quando NO_COLOR não está setado.
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  GREEN=$'\e[32m'; RED=$'\e[31m'; BOLD=$'\e[1m'; RESET=$'\e[0m'
else
  GREEN=''; RED=''; BOLD=''; RESET=''
fi

fails=0
pass() { printf "  %s✔%s %s\n" "$GREEN" "$RESET" "$1"; }
fail() { printf "  %s✗%s %s\n" "$RED" "$RESET" "$1"; fails=$((fails + 1)); }

printf "%sTrio Data Challenge — smoke test%s\n" "$BOLD" "$RESET"
printf "Compose dir: %s\n\n" "$(pwd)"

# 1) TimescaleDB — extensão carregada (critério do DoD da Sprint 00)
ts_ext="$(docker compose exec -T timescaledb \
  psql -U "$POSTGRES_USER" -d trio_transactions -tAc \
  "SELECT extversion FROM pg_extension WHERE extname='timescaledb'" 2>/dev/null \
  | tr -d '[:space:]' || true)"
if [[ -n "$ts_ext" ]]; then
  pass "TimescaleDB: extensão timescaledb v$ts_ext"
else
  fail "TimescaleDB: extensão timescaledb não encontrada"
fi

# 2) PostgreSQL legado — responde a SELECT version()
pg_ver="$(docker compose exec -T postgres-legado \
  psql -U "$POSTGRES_USER" -d trio_legado -tAc "SELECT version()" 2>/dev/null || true)"
if [[ "$pg_ver" == *PostgreSQL* ]]; then
  pass "PostgreSQL legado: ${pg_ver%% on *}"
else
  fail "PostgreSQL legado: SELECT version() falhou"
fi

# 3) ClickHouse — responde a SELECT version()
ch_ver="$(docker compose exec -T clickhouse clickhouse-client \
  --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" \
  --query "SELECT version()" 2>/dev/null | tr -d '[:space:]' || true)"
if [[ -n "$ch_ver" ]]; then
  pass "ClickHouse: v$ch_ver"
else
  fail "ClickHouse: SELECT version() falhou"
fi

# 4) Grafana — /api/health reporta database ok
gf_health="$(curl -fsS "$GRAFANA_URL/api/health" 2>/dev/null || true)"
if [[ "$gf_health" == *'"database"'*'"ok"'* ]]; then
  pass "Grafana: /api/health database=ok"
else
  fail "Grafana: /api/health não respondeu ok ($GRAFANA_URL)"
fi

# 5) Todos os containers reportam healthy
printf "\n%sHealth dos containers:%s\n" "$BOLD" "$RESET"
for c in trio-timescaledb trio-postgres-legado trio-clickhouse trio-grafana; do
  status="$(docker inspect \
    --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' \
    "$c" 2>/dev/null || echo "absent")"
  if [[ "$status" == "healthy" ]]; then
    pass "$c: $status"
  else
    fail "$c: $status"
  fi
done

printf "\n"
if [[ "$fails" -eq 0 ]]; then
  printf "%s✔ SMOKE TEST OK — ambiente saudável%s\n" "$BOLD$GREEN" "$RESET"
  exit 0
fi
printf "%s✗ SMOKE TEST FALHOU — %d verificação(ões) com erro%s\n" "$BOLD$RED" "$fails" "$RESET"
exit 1

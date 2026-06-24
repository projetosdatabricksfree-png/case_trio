#!/usr/bin/env bash
# =============================================================================
#  Trio Data Challenge — Demo de mutação do pipeline (Sprint 05 · Story 5.3)
#  Prova que pending -> settled na origem (TimescaleDB) reflete no ClickHouse
#  via ReplacingMergeTree + leitura com FINAL, SEM duplicar.
#  Uso:   ./scripts/pipeline-mutation-demo.sh   (ou: make pipeline-mutation-demo)
#  Saída: 0 = mutação refletida e sem duplicata | 1 = falhou.
#  Pré-requisitos: stack up, make migrate/seed-smoke/index, migrate-ch,
#                  migrate-pipeline (tabelas de controle). Reutilizado pelo CI.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

if [[ -f .env ]]; then
  set -a
  # shellcheck source=/dev/null
  . ./.env
  set +a
fi
POSTGRES_USER="${POSTGRES_USER:-trio}"
CLICKHOUSE_USER="${CLICKHOUSE_USER:-trio}"
CLICKHOUSE_PASSWORD="${CLICKHOUSE_PASSWORD:-trio2024}"

PSQL() { docker compose exec -T timescaledb \
  psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d trio_transactions -tAc "$1"; }
CH() { docker compose exec -T clickhouse clickhouse-client \
  --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" -d trio_analytics -q "$1"; }
RUN_PIPE() { docker compose run --rm --no-deps -T pipeline \
  python sync_ts_to_ch.py --once >/dev/null; }

echo "== Demo de mutação pending -> settled (TS -> CH) =="

# 1) Escolhe uma transação 'pending' na origem.
txid="$(PSQL "SELECT id FROM transactions WHERE status='pending' LIMIT 1")"
if [[ -z "$txid" ]]; then
  echo "FALHOU: nenhuma transação pending na origem (rode make seed-smoke)"; exit 1
fi
echo "  tx escolhida: $txid (pending na origem)"

# 2) Sincroniza e confirma o estado 'pending' no ClickHouse.
RUN_PIPE
before="$(CH "SELECT status FROM transactions FINAL WHERE id='$txid'")"
echo "  ClickHouse antes: status=${before:-<ausente>}"

# 3) Muta na origem: settled_at=now() faz o watermark efetivo avançar.
PSQL "UPDATE transactions SET status='settled', settled_at=now() WHERE id='$txid'" >/dev/null
echo "  origem mutada: pending -> settled (settled_at=now())"

# 4) Re-sincroniza: a versão maior vence no ReplacingMergeTree.
RUN_PIPE
after="$(CH "SELECT status FROM transactions FINAL WHERE id='$txid'")"
rows="$(CH "SELECT count() FROM transactions FINAL WHERE id='$txid'")"
echo "  ClickHouse depois: status=${after:-<ausente>}  (linhas FINAL=$rows)"

# 5) Validação: estado refletido e sem duplicata.
if [[ "$after" == "settled" && "$rows" == "1" ]]; then
  echo "OK: mutação refletida no ClickHouse via FINAL, sem duplicar."
  exit 0
fi
echo "FALHOU: esperado status=settled e 1 linha (FINAL); obtido status=$after linhas=$rows"
exit 1

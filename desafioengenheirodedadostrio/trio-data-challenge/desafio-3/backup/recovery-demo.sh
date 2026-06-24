#!/usr/bin/env bash
# =============================================================================
#  Trio Data Challenge — Demo de recovery do TimescaleDB (Sprint 06 · Story 6.2)
#  Recovery SELETIVO DE PERÍODO, validado com contagens e timestamps:
#    1) backup lógico do período-alvo (granule de recovery) — COPY binário,
#       robusto mesmo em chunk COMPRIMIDO (descompressão implícita no TS 2.x)
#    2) simula perda: DELETE da janela em transactions
#    3) recovery: restaura o período a partir do granule
#    4) valida que a contagem da janela (e o total) voltaram ao original
#  Uso:   ./recovery-demo.sh   (ou: make recovery-demo)
#  Saída: 0 = janela restaurada (antes == depois) | 1 = falhou.
#  Não-destrutivo no fim: re-injeta exatamente o que apagou. Reutilizado pelo CI.
#
#  Por que recovery de PERÍODO e não restore do dump inteiro: a hypertable é
#  COMPRIMIDA; restaurar o `pg_dump -Fc` completo de chunks comprimidos é frágil
#  (ordenação chunk/catalogo). O backup FULL do banco continua sendo o `pg_dump`
#  de `make backup` (DR de perda total, via timescaledb_pre_restore/post_restore —
#  ver backup/README.md). Aqui demonstramos o caminho RÁPIDO e determinístico:
#  restaurar só o período perdido a partir do granule lógico.
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
GRANULE="/tmp/recovery_window_$(date -u +%Y%m%dT%H%M%SZ).bin"

Q() {  # Q <sql> -> valor escalar (tAc) em trio_transactions
  docker compose exec -T timescaledb \
    psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d trio_transactions -tAc "$1"
}
COPY() {  # COPY <psql-\copy-command> dentro do container
  docker compose exec -T timescaledb \
    psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d trio_transactions -c "$1"
}

# Limpeza do granule no fim (trap inline -> sem função, agrada qualquer shellcheck).
trap 'docker compose exec -T timescaledb rm -f "$GRANULE" 2>/dev/null || true' EXIT

echo "== Demo de recovery TimescaleDB (perda -> recovery seletivo de período) =="

# Janela-alvo: um dia completo, 2 dias antes do último created_at (populado).
lo="$(Q "SELECT (date_trunc('day', (SELECT max(created_at) FROM transactions)) - INTERVAL '2 days')::text")"
hi="$(Q "SELECT (date_trunc('day', (SELECT max(created_at) FROM transactions)) - INTERVAL '1 day')::text")"
echo "  janela-alvo: [$lo, $hi)"

total0="$(Q "SELECT count(*) FROM transactions")"
before="$(Q "SELECT count(*) FROM transactions WHERE created_at >= '$lo' AND created_at < '$hi'")"
printf '  [%s] ANTES: total=%s · janela=%s\n' "$(date -u +%H:%M:%SZ)" "$total0" "$before"
if [[ "$before" -lt 1 ]]; then
  echo "FALHOU: janela sem dados (rode make seed-smoke)"; exit 1
fi

# 1) Backup lógico do período (granule de recovery). COPY binário = round-trip
#    exato (numeric/jsonb/timestamptz) e funciona em chunk comprimido.
echo "  [1/3] backup do período -> $GRANULE (COPY binary)"
COPY "\\copy (SELECT * FROM transactions WHERE created_at >= '$lo' AND created_at < '$hi') TO '$GRANULE' WITH (FORMAT binary)" >/dev/null

# 2) Simula perda: DELETE da janela.
echo "  [2/3] perda: DELETE da janela"
Q "DELETE FROM transactions WHERE created_at >= '$lo' AND created_at < '$hi'" >/dev/null
after_loss="$(Q "SELECT count(*) FROM transactions WHERE created_at >= '$lo' AND created_at < '$hi'")"
total_loss="$(Q "SELECT count(*) FROM transactions")"
printf '  [%s] PERDA: total=%s · janela=%s (perdidas=%s)\n' \
  "$(date -u +%H:%M:%SZ)" "$total_loss" "$after_loss" "$((before - after_loss))"

# 3) Recovery: restaura só o período a partir do granule (sem conflito de PK —
#    as linhas foram deletadas).
echo "  [3/3] recovery: restaura o período do granule"
COPY "\\copy transactions FROM '$GRANULE' WITH (FORMAT binary)" >/dev/null

after="$(Q "SELECT count(*) FROM transactions WHERE created_at >= '$lo' AND created_at < '$hi'")"
total1="$(Q "SELECT count(*) FROM transactions")"
printf '  [%s] DEPOIS: total=%s · janela=%s\n' "$(date -u +%H:%M:%SZ)" "$total1" "$after"

echo
if [[ "$after" == "$before" && "$total1" == "$total0" ]]; then
  echo "OK: recovery validado — janela e total voltaram ao estado original."
  exit 0
fi
echo "FALHOU: esperado janela=$before total=$total0; obtido janela=$after total=$total1"
exit 1

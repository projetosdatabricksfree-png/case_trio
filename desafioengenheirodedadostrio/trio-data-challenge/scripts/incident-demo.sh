#!/usr/bin/env bash
# =============================================================================
#  Trio Data Challenge — Demo do incidente SEV-1 (Sprint 07 · Story 7.1)
#  Reproduz o cenário "volume ZERO no ClickHouse": o pipeline para (stand-in do
#  security group que cortou a rede), novas transações chegam ao TimescaleDB mas
#  NÃO ao ClickHouse, os dashboards Pix ficam stale. Em seguida demonstra a
#  resolução: o pipeline volta, drena o atraso e o ClickHouse converge com o TS.
#
#  Uso:   ./scripts/incident-demo.sh   (ou: make incident-demo)
#  Saída: 0 = incidente reproduzido e resolvido (CH max == TS max) | 1 = falhou.
#  Pré-requisitos: stack up; TS semeado (make seed-smoke); CH migrado e
#                  sincronizado (make migrate-ch, migrate-pipeline, pipeline-once).
#  Reutilizado pelo CI (.github/workflows/ci.yml, passo "Sprint 07").
#
#  Determinismo: as transações injetadas têm created_at = settled_at =
#  GREATEST(now(), max(created_at)) + 25h -> garantidamente acima do watermark de
#  inserção (<= max(created_at)+window) E de max(settled_at) (<= max(created_at)+
#  latência máx), então AMBAS as passadas do pipeline (INSERT por created_at e
#  MUTATE por settled_at) as captam. Truncado ao segundo -> max(created_at) compara
#  exatamente entre timestamptz (TS) e DateTime64(3) (CH).
#  Idempotente: marcadores via metadata {"incident_demo": true}; limpos no TS no
#  início e no fim (trap). Não toca dado real do seed.
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
MARKERS="${INCIDENT_MARKERS:-50}"   # nº de transações sintéticas injetadas

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  GREEN=$'\e[32m'; RED=$'\e[31m'; YELLOW=$'\e[33m'; BOLD=$'\e[1m'; RESET=$'\e[0m'
else
  GREEN=''; RED=''; YELLOW=''; BOLD=''; RESET=''
fi

PSQL() { docker compose exec -T timescaledb \
  psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d trio_transactions -tAc "$1"; }
CH() { docker compose exec -T clickhouse clickhouse-client \
  --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" -d trio_analytics -q "$1"; }
RUN_PIPE() { docker compose run --rm --no-deps -T pipeline \
  python sync_ts_to_ch.py --once >/dev/null; }

# max(created_at) formatado ao segundo nos dois bancos (comparável como string).
TS_MAX() { PSQL "SELECT to_char(max(created_at) AT TIME ZONE 'UTC','YYYY-MM-DD HH24:MI:SS') FROM transactions"; }
# ClickHouse formatDateTime é MySQL-compatível: minuto = %i (%M seria o nome do mês).
CH_MAX() { CH "SELECT formatDateTime(max(created_at),'%Y-%m-%d %H:%i:%S') FROM transactions"; }

# Marcadores são dados de demo — removidos do TS no início (re-rodável) e no fim.
clean_markers() { PSQL "DELETE FROM transactions WHERE metadata @> '{\"incident_demo\": true}'::jsonb" >/dev/null 2>&1 || true; }
trap 'clean_markers' EXIT

printf "%s== Demo do incidente SEV-1: volume zero no ClickHouse ==%s\n" "$BOLD" "$RESET"
printf "Compose dir: %s\n\n" "$(pwd)"

clean_markers

# --- 0) Linha de base -------------------------------------------------------
ts0="$(TS_MAX)"; ch0="$(CH_MAX)"
printf "  linha de base  TS max=%s  CH max=%s\n" "${ts0:-<vazio>}" "${ch0:-<vazio>}"

# --- 1) Incidente: o pipeline para (stand-in do SG que cortou a rede) --------
printf "\n%s[1] Incidente%s — security group cortou a rota do pipeline (simulado: stop pipeline)\n" "$YELLOW" "$RESET"
docker compose stop pipeline >/dev/null 2>&1 || true

# Novas transações chegam ao TS (settled_at=now()) — clientes seguem transacionando.
PSQL "
  INSERT INTO transactions
    (id, external_id, amount, currency, status, type,
     source_institution, destination_institution,
     source_account_id, destination_account_id,
     created_at, settled_at, metadata)
  SELECT gen_random_uuid(), gen_random_uuid(), 100.00, 'BRL', 'settled', 'pix',
         source_institution, destination_institution,
         gen_random_uuid(), gen_random_uuid(),
         date_trunc('second', GREATEST(now(), (SELECT max(created_at) FROM transactions))) + INTERVAL '25 hours',
         date_trunc('second', GREATEST(now(), (SELECT max(created_at) FROM transactions))) + INTERVAL '25 hours',
         '{\"incident_demo\": true}'::jsonb
    FROM transactions
   LIMIT ${MARKERS}" >/dev/null
printf "      %s novas transações no TimescaleDB (clientes transacionando normalmente)\n" "$MARKERS"

# --- 2) Investigação: isolar a camada --------------------------------------
printf "\n%s[2] Investigação%s\n" "$YELLOW" "$RESET"
ts1="$(TS_MAX)"; ch1="$(CH_MAX)"
last_run="$(CH "SELECT ifNull(toString(max(finished_at)),'<nunca>') FROM pipeline_runs WHERE pipeline='ts_to_ch'")"
printf "      TimescaleDB max(created_at) = %s  (recente — origem saudável)\n" "$ts1"
printf "      ClickHouse  max(created_at) = %s  (defasado — dashboards Pix stale)\n" "$ch1"
printf "      pipeline_runs última execução = %s\n" "$last_run"
printf "      => TS tem dado novo e o CH não: a camada quebrada é o PIPELINE (não drena),\n"
printf "         consistente com o SG bloqueando a porta do pipeline.\n"

if [[ "$ts1" == "$ch1" ]]; then
  printf "  %s✗%s pré-condição não satisfeita: não há defasagem CH vs TS (rode os pré-requisitos).\n" "$RED" "$RESET"
  exit 1
fi
printf "  %s✔%s defasagem confirmada: CH atrás do TS.\n" "$GREEN" "$RESET"

# --- 3) Resolução: pipeline volta e drena o atraso --------------------------
printf "\n%s[3] Resolução%s — regra do SG restaurada; pipeline drena o atraso\n" "$YELLOW" "$RESET"
printf "      (em produção: aws ec2 authorize-security-group-ingress + restart do serviço)\n"
RUN_PIPE

# --- 4) Validação: ClickHouse convergiu com o TimescaleDB -------------------
printf "\n%s[4] Validação%s\n" "$YELLOW" "$RESET"
ts2="$(TS_MAX)"; ch2="$(CH_MAX)"
printf "      TimescaleDB max(created_at) = %s\n" "$ts2"
printf "      ClickHouse  max(created_at) = %s\n" "$ch2"

# Restaura o serviço contínuo (pós-incidente: pipeline rodando) — fora do caminho de asserção.
docker compose start pipeline >/dev/null 2>&1 || true

if [[ -n "$ch2" && "$ch2" == "$ts2" ]]; then
  printf "\n%s✔ OK%s — incidente reproduzido e resolvido: ClickHouse convergiu (CH max == TS max).\n" "$GREEN" "$RESET"
  exit 0
fi
printf "\n%s✗ FALHOU%s — esperado CH max == TS max; obtido CH=%s TS=%s\n" "$RED" "$RESET" "$ch2" "$ts2"
exit 1

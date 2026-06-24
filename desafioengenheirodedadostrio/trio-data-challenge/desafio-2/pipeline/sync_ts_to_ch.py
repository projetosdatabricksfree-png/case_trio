"""Pipeline principal TimescaleDB -> ClickHouse (micro-batch idempotente).

Story 5.2/5.3. A origem é uma HYPERTABLE COMPRIMIDA (política da Sprint 02): leitura
ordenada global por expressão custaria um Sort de milhões por batch. Então lemos de
forma amigável ao armazenamento colunar comprimido, em DUAS passadas:

  - INSERT pass — janelas de tempo half-open sobre `created_at` (coluna de partição
    e orderby da compressão): `created_at >= lo AND created_at < hi`. O TimescaleDB
    poda para 1 chunk por janela (sem Sort, sem varrer a tabela inteira). Cobre todo
    o backfill e quaisquer linhas novas.
  - MUTATE pass — keyset `(settled_at, id)` sobre as linhas liquidadas: captura
    mutações pending -> settled (settled_at recebe um timestamp > tudo no seed).
    Inicializa o watermark em max(settled_at) da origem -> só pega mutações futuras.

Idempotência = watermark (não relê o inalterado) + `ReplacingMergeTree(version)`
(colapsa o reinserido). O `id`/`external_id` da ORIGEM são carregados explicitamente
(NÃO o DEFAULT do servidor): é o que garante que a tupla ORDER BY do ClickHouse seja
idêntica entre versões e o Replacing deduplique. `version` = COALESCE(settled_at,
created_at) (= settled_at na passada de mutação) -> a versão mais recente vence.

Observabilidade = logs JSON + tabela `pipeline_runs`. Resiliência = retry com backoff
exponencial; dado poison vai para `pipeline_dlq`.

Modos:
  --once       drena (insert + mutate) e sai (determinístico p/ make/CI).
  (default)    loop contínuo: poll a cada PIPELINE_POLL_S, heartbeat p/ healthcheck.
  --demo-dlq   injeta 1 registro sintético inválido pela via de DLQ (fault-injection).
"""
from __future__ import annotations

import argparse
import json
import sys
import time
import uuid
from datetime import datetime, timedelta, timezone

import clickhouse_connect
import psycopg
from psycopg.rows import dict_row

from pipeline_config import PipelineConfig, load_pipeline_config
from pipeline_logging import get_logger, log

INSERT_KEY = "ts_to_ch_insert"   # watermark da passada de inserção (created_at)
MUTATE_KEY = "ts_to_ch_mutate"   # watermark da passada de mutação (settled_at)
HEARTBEAT = "/tmp/pipeline.heartbeat"
EPOCH = datetime(1970, 1, 1, tzinfo=timezone.utc)
ZERO_UUID = "00000000-0000-0000-0000-000000000000"
MAX_UUID = "ffffffff-ffff-ffff-ffff-ffffffffffff"

VALID_STATUS = {"pending", "settled", "failed", "reversed"}
VALID_TYPE = {"pix", "ted", "boleto", "card"}

# Ordem das colunas no INSERT do ClickHouse (espelha 01_transactions.sql).
CH_COLUMNS = [
    "id", "external_id", "amount", "currency", "status", "type",
    "source_institution", "destination_institution",
    "source_account_id", "destination_account_id",
    "created_at", "settled_at", "version",
]

_SELECT = """
    SELECT id::text AS id, external_id::text AS external_id, amount,
           currency, status, type, source_institution, destination_institution,
           source_account_id::text  AS source_account_id,
           destination_account_id::text AS destination_account_id,
           created_at, settled_at, {version} AS version
    FROM transactions
"""
# Janela de tempo half-open: poda de chunk, sem Sort (amigável a chunk comprimido).
READ_WINDOW_SQL = _SELECT.format(version="COALESCE(settled_at, created_at)") + \
    " WHERE created_at >= %(lo)s AND created_at < %(hi)s"
# Keyset sobre linhas liquidadas: captura mutações pending -> settled.
READ_MUTATIONS_SQL = _SELECT.format(version="settled_at") + \
    """ WHERE settled_at IS NOT NULL AND (settled_at, id) > (%(wm)s, %(wm_id)s::uuid)
        ORDER BY settled_at, id LIMIT %(batch)s"""


def heartbeat() -> None:
    """Toca o heartbeat (healthcheck do compose). Escrito ANTES de qualquer acesso a
    banco e a cada janela -> healthy mesmo aguardando o schema ou em backfill longo."""
    try:
        with open(HEARTBEAT, "w") as fh:
            fh.write(datetime.now(timezone.utc).isoformat())
    except OSError:
        pass


def ch_connect(cfg: PipelineConfig):
    return clickhouse_connect.get_client(
        host=cfg.ch_host, port=cfg.ch_port, username=cfg.ch_user,
        password=cfg.ch_password, database=cfg.ch_db,
    )


def with_retry(fn, cfg: PipelineConfig, logger, op: str):
    """Executa `fn` com retry + backoff exponencial em erro transitório."""
    last_exc = None
    for attempt in range(cfg.max_retries + 1):
        try:
            return fn()
        except Exception as exc:  # noqa: BLE001 — transitório (rede/banco); decidimos pelo retry
            last_exc = exc
            if attempt >= cfg.max_retries:
                break
            delay = cfg.backoff_base_s * (2 ** attempt)
            log(logger, "pipeline.retry", op=op, attempt=attempt + 1,
                delay_s=round(delay, 3), error=str(exc))
            time.sleep(delay)
    raise last_exc


def read_watermark(ch, key: str) -> tuple[datetime, str]:
    """Último watermark confirmado p/ `key` (argMax pelo committed_at). Tabela vazia
    -> defaults do tipo (1970 / zero-uuid)."""
    res = ch.query(
        "SELECT argMax(last_value, committed_at), argMax(last_id, committed_at) "
        "FROM pipeline_watermark WHERE pipeline = {p:String}",
        parameters={"p": key},
    )
    if not res.result_rows or res.result_rows[0][0] is None:
        return EPOCH, ZERO_UUID
    value, last_id = res.result_rows[0]
    # argMax perde a anotação 'UTC' do DateTime64 -> clickhouse-connect devolve naive;
    # reanexa UTC p/ comparar/parametrizar contra o timestamptz (aware) do PostgreSQL.
    if value.tzinfo is None:
        value = value.replace(tzinfo=timezone.utc)
    return value, str(last_id)


def commit_watermark(ch, key: str, value: datetime, last_id: str, rows: int) -> None:
    ch.insert(
        "pipeline_watermark",
        [[key, value, last_id, rows]],
        column_names=["pipeline", "last_value", "last_id", "rows_committed"],
    )


def validate(row: dict) -> None:
    """Valida o registro; levanta ValueError em dado poison (-> DLQ)."""
    if row["amount"] is None or row["amount"] <= 0:
        raise ValueError(f"amount inválido: {row['amount']!r}")
    if row["status"] not in VALID_STATUS:
        raise ValueError(f"status fora do domínio: {row['status']!r}")
    if row["type"] not in VALID_TYPE:
        raise ValueError(f"type fora do domínio: {row['type']!r}")
    if row["created_at"] is None:
        raise ValueError("created_at nulo")


def to_ch_row(row: dict) -> list:
    return [
        row["id"], row["external_id"], row["amount"], row["currency"],
        row["status"], row["type"], row["source_institution"],
        row["destination_institution"], row["source_account_id"],
        row["destination_account_id"], row["created_at"], row["settled_at"],
        row["version"],
    ]


def build_batch(ch, logger, rows: list) -> list:
    """Valida cada linha; poison -> DLQ (não trava o batch); válidas -> linhas do CH."""
    data = []
    for row in rows:
        try:
            validate(row)
            data.append(to_ch_row(row))
        except ValueError as exc:
            to_dlq(ch, logger, row, exc, 0)
    return data


def to_dlq(ch, logger, payload: dict, error, retries: int) -> None:
    ch.insert(
        "pipeline_dlq",
        [[INSERT_KEY.rsplit("_", 1)[0], json.dumps(payload, default=str),
          str(error), retries]],
        column_names=["pipeline", "payload", "error", "retries"],
    )
    log(logger, "pipeline.dlq", error=str(error))


def _query(pg, sql: str, params: dict) -> list:
    with pg.cursor(row_factory=dict_row) as cur:
        cur.execute(sql, params)
        return cur.fetchall()


def created_bounds(pg) -> tuple[datetime | None, datetime | None]:
    with pg.cursor() as cur:
        cur.execute("SELECT min(created_at), max(created_at) FROM transactions")
        return cur.fetchone()


def settled_max(pg) -> datetime | None:
    with pg.cursor() as cur:
        cur.execute("SELECT max(settled_at) FROM transactions")
        return cur.fetchone()[0]


def insert_pass(pg, ch, cfg, logger) -> tuple[int, int, datetime]:
    """Janelas half-open sobre created_at: cobre backfill + linhas novas."""
    src_min, src_max = created_bounds(pg)
    wm, _ = read_watermark(ch, INSERT_KEY)
    if src_max is None:
        return 0, 0, wm
    if wm < src_min:                                  # 1ª execução: começa no início do dado
        wm = src_min
    window = timedelta(hours=cfg.window_hours)
    rows_read = rows_written = 0
    lo = wm
    while lo <= src_max:
        heartbeat()
        hi = lo + window
        batch = with_retry(lambda: _query(pg, READ_WINDOW_SQL, {"lo": lo, "hi": hi}),
                           cfg, logger, "read_window")
        rows_read += len(batch)
        data = build_batch(ch, logger, batch)
        if data:
            with_retry(lambda: ch.insert("transactions", data, column_names=CH_COLUMNS),
                       cfg, logger, "insert")
            rows_written += len(data)
        with_retry(lambda: commit_watermark(ch, INSERT_KEY, hi, ZERO_UUID, len(batch)),
                   cfg, logger, "commit_insert")
        lo = hi
    if rows_read:
        log(logger, "pipeline.insert_pass", rows_read=rows_read, rows_written=rows_written)
    # `lo` é o limite superior alcançado (> src_max quando alcançado) -> lag 0 ao fim.
    return rows_read, rows_written, lo


def mutate_pass(pg, ch, cfg, logger) -> tuple[int, int]:
    """Keyset sobre settled_at: captura mutações pending -> settled. Inicializa o
    watermark em max(settled_at) -> não re-sincroniza tudo, só mutações futuras."""
    wm, wm_id = read_watermark(ch, MUTATE_KEY)
    if wm <= EPOCH:                                   # 1ª execução: pula o estado já coberto pelo insert pass
        smax = settled_max(pg)
        # last_id = MAX_UUID -> a fronteira exata em max(settled_at) não é re-lida;
        # mutações futuras (settled_at = now() > max) são captadas.
        commit_watermark(ch, MUTATE_KEY, smax or EPOCH, MAX_UUID, 0)
        return 0, 0
    rows_read = rows_written = 0
    while True:
        heartbeat()
        params = {"wm": wm, "wm_id": wm_id, "batch": cfg.batch}
        batch = with_retry(lambda: _query(pg, READ_MUTATIONS_SQL, params),
                           cfg, logger, "read_mutations")
        if not batch:
            break
        rows_read += len(batch)
        data = build_batch(ch, logger, batch)
        if data:
            with_retry(lambda: ch.insert("transactions", data, column_names=CH_COLUMNS),
                       cfg, logger, "insert")
            rows_written += len(data)
        last = batch[-1]
        wm, wm_id = last["settled_at"], last["id"]
        with_retry(lambda: commit_watermark(ch, MUTATE_KEY, wm, wm_id, len(batch)),
                   cfg, logger, "commit_mutate")
        if len(batch) < cfg.batch:
            break
    if rows_read:
        log(logger, "pipeline.mutate_pass", rows_read=rows_read, rows_written=rows_written)
    return rows_read, rows_written


def drain(pg, ch, cfg, logger) -> tuple[int, int, float]:
    """Uma passada completa: backfill/novos (insert) + mutações. Retorna métricas + lag."""
    ins_r, ins_w, ins_wm = insert_pass(pg, ch, cfg, logger)
    mut_r, mut_w = mutate_pass(pg, ch, cfg, logger)
    _, src_max = created_bounds(pg)
    lag = _lag(src_max, ins_wm)
    return ins_r + mut_r, ins_w + mut_w, lag


def record_run(ch, started, finished, rows_read, rows_written, lag, status, error="") -> None:
    duration_ms = int((finished - started).total_seconds() * 1000)
    ch.insert(
        "pipeline_runs",
        [[str(uuid.uuid4()), "ts_to_ch", started, finished, rows_read,
          rows_written, float(lag), duration_ms, status, error]],
        column_names=["run_id", "pipeline", "started_at", "finished_at", "rows_read",
                      "rows_written", "lag_seconds", "duration_ms", "status", "error"],
    )


def _lag(src_max: datetime | None, wm: datetime) -> float:
    """Lag RELATIVO À ORIGEM: max(created_at origem) − watermark de inserção. 0 quando
    alcançado. Seed é estático, então freshness vs. now() não faria sentido."""
    if src_max is None:
        return 0.0
    return max(0.0, (src_max - wm).total_seconds())


def _cycle(cfg: PipelineConfig, logger, started):
    ch = ch_connect(cfg)
    with psycopg.connect(cfg.pg_conninfo, autocommit=True) as pg:
        with pg.cursor() as cur:
            cur.execute("SET TIME ZONE 'UTC'")
        rows_read, rows_written, lag = drain(pg, ch, cfg, logger)
    finished = datetime.now(timezone.utc)
    return ch, rows_read, rows_written, lag, finished


def run_once(cfg: PipelineConfig, logger) -> int:
    started = datetime.now(timezone.utc)
    heartbeat()
    try:
        ch, rows_read, rows_written, lag, finished = _cycle(cfg, logger, started)
        record_run(ch, started, finished, rows_read, rows_written, lag, "ok")
        log(logger, "pipeline.once.done", rows_read=rows_read, rows_written=rows_written,
            lag_seconds=round(lag, 3))
        return 0
    except Exception as exc:  # noqa: BLE001
        finished = datetime.now(timezone.utc)
        try:
            record_run(ch_connect(cfg), started, finished, 0, 0, 0.0, "error", str(exc))
        except Exception:  # noqa: BLE001 — schema pode nem existir
            pass
        log(logger, "pipeline.once.error", error=str(exc))
        return 1


def run_loop(cfg: PipelineConfig, logger) -> int:
    log(logger, "pipeline.loop.start", poll_s=cfg.poll_s, window_hours=cfg.window_hours)
    while True:
        heartbeat()                              # antes do DB -> healthy mesmo aguardando schema
        started = datetime.now(timezone.utc)
        try:
            ch, rows_read, rows_written, lag, finished = _cycle(cfg, logger, started)
            if rows_read > 0:                    # só registra ciclos que fizeram trabalho
                record_run(ch, started, finished, rows_read, rows_written, lag, "ok")
            log(logger, "pipeline.loop.cycle", rows_read=rows_read,
                rows_written=rows_written, lag_seconds=round(lag, 3))
        except Exception as exc:  # noqa: BLE001 — schema ausente/transitório: espera e tenta de novo
            log(logger, "pipeline.loop.waiting", hint="rode make migrate-pipeline",
                error=str(exc))
        time.sleep(cfg.poll_s)


def demo_dlq(cfg: PipelineConfig, logger) -> int:
    """Fault-injection deliberado: 1 registro sintético inválido -> DLQ. Não toca
    dado real; prova o mecanismo de dead-letter de forma determinística (CI)."""
    ch = ch_connect(cfg)
    poison = {
        "id": str(uuid.uuid4()), "amount": "-1.00", "status": "BOGUS", "type": "pix",
        "created_at": datetime.now(timezone.utc).isoformat(),
        "note": "registro sintético de fault-injection (demo de DLQ)",
    }
    try:
        validate({"amount": -1, "status": "BOGUS", "type": "pix",
                  "created_at": datetime.now(timezone.utc)})
    except ValueError as exc:
        to_dlq(ch, logger, poison, exc, cfg.max_retries)
        log(logger, "pipeline.demo_dlq.done", routed=1)
        return 0
    return 1


def main() -> int:
    parser = argparse.ArgumentParser(description="Pipeline TimescaleDB -> ClickHouse")
    parser.add_argument("--once", action="store_true",
                        help="drena uma vez (insert + mutate) e sai")
    parser.add_argument("--demo-dlq", action="store_true",
                        help="injeta 1 registro inválido pela via de DLQ e sai")
    args = parser.parse_args()

    cfg = load_pipeline_config()
    logger = get_logger("pipeline-ts-ch")
    heartbeat()

    if args.demo_dlq:
        return demo_dlq(cfg, logger)
    if args.once:
        return run_once(cfg, logger)
    return run_loop(cfg, logger)


if __name__ == "__main__":
    sys.exit(main())

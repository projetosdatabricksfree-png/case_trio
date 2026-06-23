"""Pipeline secundário PostgreSQL legado -> ClickHouse (dados de referência).

Story 5.4. Full-refresh idempotente de `institution_configs` (trio_legado) para a
tabela `ref_institutions` no ClickHouse (~30 linhas) e, em seguida,
`SYSTEM RELOAD DICTIONARY` para o dictionary da Sprint 04 refletir mudanças na hora
(sem esperar o LIFETIME). O dictionary SEGUE lendo o PostgreSQL direto (Sprint 04
intacta); este pipeline materializa a cópia consultável e força o refresh.

Frequência: referência muda pouco -> one-shot/cron (full refresh de poucas linhas
é mais simples e seguro que CDC aqui). RESILIÊNCIA À MIGRAÇÃO Aurora: só muda a
connection string/endpoint (Aurora é wire-compatible com PostgreSQL); a lógica
deste pipeline permanece idêntica — desacoplamento via env (ver ADR).
"""
from __future__ import annotations

import argparse
import sys
import time
import uuid
from datetime import datetime, timezone

import clickhouse_connect
import psycopg

from pipeline_config import PipelineConfig, load_pipeline_config
from pipeline_logging import get_logger, log

PIPELINE_NAME = "pg_refs"
DICTIONARY = "trio_analytics.dict_institutions"

REF_COLUMNS = ["institution_code", "institution_name", "short_name",
               "type", "settlement_window", "active"]

READ_SQL = """
    SELECT institution_code, institution_name, short_name,
           type, settlement_window, active::int AS active
    FROM institution_configs
    ORDER BY institution_code
"""


def record_run(ch, started, finished, rows, status, error="") -> None:
    duration_ms = int((finished - started).total_seconds() * 1000)
    ch.insert(
        "pipeline_runs",
        [[str(uuid.uuid4()), PIPELINE_NAME, started, finished, rows, rows,
          0.0, duration_ms, status, error]],
        column_names=["run_id", "pipeline", "started_at", "finished_at", "rows_read",
                      "rows_written", "lag_seconds", "duration_ms", "status", "error"],
    )


def run_once(cfg: PipelineConfig, logger) -> int:
    started = datetime.now(timezone.utc)
    ch = clickhouse_connect.get_client(
        host=cfg.ch_host, port=cfg.ch_port, username=cfg.ch_user,
        password=cfg.ch_password, database=cfg.ch_db,
    )
    try:
        with psycopg.connect(cfg.pg_conninfo, autocommit=True) as pg:
            with pg.cursor() as cur:
                cur.execute(READ_SQL)
                rows = cur.fetchall()

        # Full refresh idempotente: zera e reinsere o snapshot atual.
        ch.command("TRUNCATE TABLE IF EXISTS ref_institutions")
        if rows:
            ch.insert("ref_institutions", [list(r) for r in rows], column_names=REF_COLUMNS)

        # Força o dictionary (que lê o PG direto) a recarregar já — sem esperar o LIFETIME.
        try:
            ch.command(f"SYSTEM RELOAD DICTIONARY {DICTIONARY}")
            reloaded = True
        except Exception as exc:  # noqa: BLE001 — dict pode não existir (migrate-ch não rodou)
            reloaded = False
            log(logger, "pipeline.refs.reload_skip", error=str(exc))

        finished = datetime.now(timezone.utc)
        record_run(ch, started, finished, len(rows), "ok")
        log(logger, "pipeline.refs.done", rows=len(rows), dictionary_reloaded=reloaded)
        return 0
    except Exception as exc:  # noqa: BLE001
        finished = datetime.now(timezone.utc)
        try:
            record_run(ch, started, finished, 0, "error", str(exc))
        except Exception:  # noqa: BLE001
            pass
        log(logger, "pipeline.refs.error", error=str(exc))
        return 1


def main() -> int:
    parser = argparse.ArgumentParser(description="Pipeline de referência PostgreSQL -> ClickHouse")
    parser.add_argument("--once", action="store_true",
                        help="executa um full-refresh e sai (comportamento padrão)")
    parser.add_argument("--interval-s", type=float, default=0.0,
                        help="se > 0, repete o refresh a cada N segundos (cron-like)")
    args = parser.parse_args()

    cfg = load_pipeline_config()
    logger = get_logger("pipeline-pg-refs")

    if args.interval_s and not args.once:
        log(logger, "pipeline.refs.loop.start", interval_s=args.interval_s)
        while True:
            run_once(cfg, logger)
            time.sleep(args.interval_s)
    return run_once(cfg, logger)


if __name__ == "__main__":
    sys.exit(main())

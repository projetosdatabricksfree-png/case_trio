"""Orquestrador do seed do ClickHouse (entrypoint do container `seeder-clickhouse`).

Sequência: conecta -> TRUNCATE (base + targets das MVs, p/ idempotência) -> carga
em lotes -> log de contagem/timing. As MVs (mv_tx_daily_summary, mv_tx_status_funnel)
materializam automaticamente nos INSERTs da carga — por isso o schema (make migrate-ch)
roda ANTES do seed. NÃO cria índices/dictionary (responsabilidade do migrate-ch).
"""
from __future__ import annotations

import sys
import time

import clickhouse_connect

import seed_clickhouse
from ch_config import load_ch_config
from config import get_logger, log


def main() -> int:
    cfg = load_ch_config()
    logger = get_logger("seeder-clickhouse")
    log(logger, "seed.clickhouse.start", host=cfg.host, database=cfg.database,
        seed_tx=cfg.seed_tx, batch=cfg.batch, rng_seed=cfg.rng_seed)

    started = time.perf_counter()
    client = clickhouse_connect.get_client(
        host=cfg.host, port=cfg.port, username=cfg.user,
        password=cfg.password, database=cfg.database,
    )

    # Idempotência: zera base e targets das MVs; os novos INSERTs repreenchem ambos.
    for tbl in ("transactions", "tx_daily_summary", "tx_status_funnel"):
        client.command(f"TRUNCATE TABLE IF EXISTS {cfg.database}.{tbl}")

    n = seed_clickhouse.run(client, cfg, logger)

    elapsed = round(time.perf_counter() - started, 1)
    log(logger, "seed.clickhouse.done", transactions=n, elapsed_s=elapsed)
    return 0


if __name__ == "__main__":
    sys.exit(main())

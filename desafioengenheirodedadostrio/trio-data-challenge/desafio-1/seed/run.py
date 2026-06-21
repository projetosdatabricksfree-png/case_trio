"""Orquestrador do seed (entrypoint do container `seeder`).

Sequência: TRUNCATE (idempotência) -> institutions -> accounts -> transactions
-> reconciliation -> ANALYZE. Loga timings e contagens em JSON. NÃO cria os
índices secundários — isso é responsabilidade do `make index` (06_indexes.sql),
aplicado pós-seed para não pesar o COPY.
"""
from __future__ import annotations

import sys
import time

import psycopg

import seed_accounts
import seed_institutions
import seed_reconciliation
import seed_transactions
from config import get_logger, load_config, log


def main() -> int:
    cfg = load_config()
    logger = get_logger()
    log(logger, "seed.start", **cfg.public())

    started = time.perf_counter()
    with psycopg.connect(cfg.conninfo, autocommit=False) as conn:
        # Idempotência: recomeça do zero a cada execução (CASCADE cobre as FKs).
        with conn.cursor() as cur:
            cur.execute(
                "TRUNCATE reconciliation_events, transactions, accounts, "
                "institutions RESTART IDENTITY CASCADE"
            )
        conn.commit()

        n_inst = seed_institutions.run(conn, cfg, logger)
        n_acc = seed_accounts.run(conn, cfg, logger)
        account_ids = seed_accounts.fetch_account_ids(conn)
        n_tx = seed_transactions.run(conn, cfg, logger, account_ids)
        n_rec = seed_reconciliation.run(cfg, logger)

        log(logger, "seed.analyze.start")
        with conn.cursor() as cur:
            cur.execute("ANALYZE transactions")
            cur.execute("ANALYZE accounts")
            cur.execute("ANALYZE reconciliation_events")
        conn.commit()

    elapsed = round(time.perf_counter() - started, 1)
    log(
        logger, "seed.done",
        institutions=n_inst, accounts=n_acc, transactions=n_tx,
        reconciliation=n_rec, elapsed_s=elapsed,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())

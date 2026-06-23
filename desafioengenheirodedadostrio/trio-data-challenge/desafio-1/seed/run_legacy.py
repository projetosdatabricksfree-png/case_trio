"""Orquestrador do seed do LEGADO (entrypoint do container `seeder-legado`).

Sequência: TRUNCATE -> configs -> partners -> users -> accounts -> limits ->
ANALYZE. Reusa a conexão de config.load_config() (PGHOST/PGDATABASE sobrescritos
pelo compose para postgres-legado/trio_legado). NÃO cria os índices de apoio —
isso é do `make index-legado` (06_indexes_legacy.sql), pós-seed, para preservar o
EXPLAIN "antes/depois" das queries.
"""
from __future__ import annotations

import sys
import time

import psycopg

import seed_legacy
from config import get_logger, load_config, log
from generators import make_rng
from legacy_config import load_legacy_config


def main() -> int:
    cfg = load_config()
    lcfg = load_legacy_config()
    logger = get_logger("seeder-legado")
    log(logger, "seed.legacy.start", dbname=cfg.dbname, host=cfg.host,
        users=lcfg.users, accounts_per_user=lcfg.accounts_per_user, rng_seed=lcfg.rng_seed)

    started = time.perf_counter()
    rng, _ = make_rng(lcfg.rng_seed)
    with psycopg.connect(cfg.conninfo, autocommit=False) as conn:
        # Idempotência: recomeça do zero (CASCADE cobre as FKs); RESTART IDENTITY
        # zera as sequências para que o seed seja reprodutível.
        with conn.cursor() as cur:
            cur.execute(
                "TRUNCATE account_limits, accounts, users, institution_partners, "
                "institution_configs RESTART IDENTITY CASCADE"
            )
        conn.commit()

        n_cfg = seed_legacy.seed_configs(conn, logger)
        n_par = seed_legacy.seed_partners(conn, rng, logger)
        n_usr = seed_legacy.seed_users(conn, lcfg, logger)
        user_ids = seed_legacy.fetch_ids(conn, "users")
        n_acc = seed_legacy.seed_accounts(conn, lcfg, logger, user_ids)
        account_ids = seed_legacy.fetch_ids(conn, "accounts")
        n_lim = seed_legacy.seed_limits(conn, lcfg, logger, account_ids)

        log(logger, "seed.legacy.analyze.start")
        with conn.cursor() as cur:
            for tbl in ("institution_configs", "institution_partners",
                        "users", "accounts", "account_limits"):
                cur.execute(f"ANALYZE {tbl}")
        conn.commit()

    elapsed = round(time.perf_counter() - started, 1)
    log(logger, "seed.legacy.done", institution_configs=n_cfg, institution_partners=n_par,
        users=n_usr, accounts=n_acc, account_limits=n_lim, elapsed_s=elapsed)
    return 0


if __name__ == "__main__":
    sys.exit(main())

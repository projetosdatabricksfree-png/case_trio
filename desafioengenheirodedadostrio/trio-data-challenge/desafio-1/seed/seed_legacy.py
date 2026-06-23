"""Loaders COPY do legado (trio_legado): configs, partners, users, accounts, limits.

Reusa os helpers do seed do TimescaleDB (generators.make_rng/inst_codes_weights,
config.log) e o idioma de PII de seed_accounts.py (CPF/CNPJ via Faker pt_BR).
Tabelas com `id` IDENTITY (users/accounts/partners) ficam fora do COPY → o servidor
gera as chaves; recuperamos os ids com fetch_ids para amarrar as FKs.
"""
from __future__ import annotations

import re

import numpy as np
import psycopg
from faker import Faker

from config import Config, log
from generators import inst_codes_weights, make_rng
from legacy_config import LegacyConfig, configs_rows, partners_rows

_DIGITS = re.compile(r"\D")


def fetch_ids(conn: psycopg.Connection, table: str) -> list[int]:
    with conn.cursor() as cur:
        cur.execute(f"SELECT id FROM {table} ORDER BY id")
        return [int(row[0]) for row in cur.fetchall()]


def seed_configs(conn: psycopg.Connection, logger) -> int:
    sql = (
        "COPY institution_configs (institution_code, institution_name, short_name, "
        "type, settlement_window, fee_schedule, api_endpoint, max_tx_per_day, "
        "supports_pix, active) FROM STDIN"
    )
    rows = configs_rows()
    with conn.cursor() as cur, cur.copy(sql) as copy:
        for row in rows:
            copy.write_row(row)
    conn.commit()
    log(logger, "seed.legacy.configs", count=len(rows))
    return len(rows)


def seed_partners(conn: psycopg.Connection, rng: np.random.Generator, logger) -> int:
    sql = (
        "COPY institution_partners (institution_code, partner_name, partnership_type, "
        "contract_status, fee_share) FROM STDIN"
    )
    rows = partners_rows(rng)
    with conn.cursor() as cur, cur.copy(sql) as copy:
        for row in rows:
            copy.write_row(row)
    conn.commit()
    log(logger, "seed.legacy.partners", count=len(rows))
    return len(rows)


def seed_users(conn: psycopg.Connection, lcfg: LegacyConfig, logger) -> int:
    fake = Faker("pt_BR")
    Faker.seed(lcfg.rng_seed)
    _, pyrand = make_rng(lcfg.rng_seed)

    n = lcfg.users
    sql = "COPY users (full_name, document, email, status) FROM STDIN"
    statuses = ("active", "suspended", "closed")
    with conn.cursor() as cur, cur.copy(sql) as copy:
        for _ in range(n):
            is_company = pyrand.random() < 0.10
            doc = _DIGITS.sub("", fake.cnpj() if is_company else fake.cpf())
            name = fake.company() if is_company else fake.name()
            email = fake.ascii_company_email() if is_company else fake.ascii_free_email()
            r = pyrand.random()
            status = "active" if r < 0.92 else (statuses[1] if r < 0.97 else statuses[2])
            copy.write_row((name, doc, email, status))
    conn.commit()
    log(logger, "seed.legacy.users", count=n)
    return n


def seed_accounts(conn: psycopg.Connection, lcfg: LegacyConfig, logger,
                  user_ids: list[int]) -> int:
    rng, pyrand = make_rng(lcfg.rng_seed + 1)
    n = int(lcfg.users * lcfg.accounts_per_user)

    codes, weights = inst_codes_weights()
    probs = weights / weights.sum()
    inst_idx = rng.choice(len(codes), size=n, p=probs)
    acc_types = rng.choice(["checking", "savings", "payment"], size=n, p=[0.60, 0.25, 0.15])
    statuses = rng.choice(["active", "blocked", "closed"], size=n, p=[0.93, 0.04, 0.03])
    balances = np.round(rng.lognormal(mean=7.0, sigma=1.4, size=n), 2)  # cauda de grandes
    owners = rng.integers(0, len(user_ids), size=n)
    users_arr = np.array(user_ids)

    sql = (
        "COPY accounts (user_id, institution_code, account_number, account_type, "
        "status, balance) FROM STDIN"
    )
    with conn.cursor() as cur, cur.copy(sql) as copy:
        for i in range(n):
            account_number = f"{pyrand.randint(1, 9999):04d}-{pyrand.randint(0, 9)}"
            copy.write_row((
                int(users_arr[owners[i]]),
                str(codes[inst_idx[i]]),
                account_number,
                str(acc_types[i]),
                str(statuses[i]),
                float(balances[i]),
            ))
    conn.commit()
    log(logger, "seed.legacy.accounts", count=n)
    return n


def seed_limits(conn: psycopg.Connection, lcfg: LegacyConfig, logger,
                account_ids: list[int]) -> int:
    rng, _ = make_rng(lcfg.rng_seed + 2)
    n = len(account_ids)
    # Limite diário log-normal INDEPENDENTE do saldo → parte das contas tem
    # balance > daily_limit (garante linhas para a Story 3.3).
    daily = np.round(rng.lognormal(mean=6.5, sigma=1.0, size=n), 2)
    monthly = np.round(daily * rng.uniform(20, 30, size=n), 2)
    per_tx = np.round(daily * rng.uniform(0.2, 0.6, size=n), 2)

    sql = (
        "COPY account_limits (account_id, daily_limit, monthly_limit, per_tx_limit) "
        "FROM STDIN"
    )
    with conn.cursor() as cur, cur.copy(sql) as copy:
        for i in range(n):
            copy.write_row((
                account_ids[i],
                float(daily[i]),
                float(monthly[i]),
                float(per_tx[i]),
            ))
    conn.commit()
    log(logger, "seed.legacy.limits", count=n)
    return n

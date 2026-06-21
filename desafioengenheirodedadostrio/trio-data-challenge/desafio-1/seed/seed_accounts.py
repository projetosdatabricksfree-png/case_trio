"""Carga da dimensão `accounts` com documentos PII plausíveis (Faker pt_BR)."""
from __future__ import annotations

import re

import psycopg
from faker import Faker

from config import Config, log
from generators import inst_codes_weights, make_rng

_COPY_SQL = (
    "COPY accounts (account_number, institution_code, holder_document, "
    "holder_name, account_type, status) FROM STDIN"
)
_DIGITS = re.compile(r"\D")


def run(conn: psycopg.Connection, cfg: Config, logger) -> int:
    rng, pyrand = make_rng(cfg.rng_seed)
    fake = Faker("pt_BR")
    Faker.seed(cfg.rng_seed)

    n = cfg.seed_accounts
    codes, weights = inst_codes_weights()
    probs = weights / weights.sum()

    inst_idx = rng.choice(len(codes), size=n, p=probs)
    acc_types = rng.choice(["checking", "savings", "payment"], size=n, p=[0.60, 0.25, 0.15])
    statuses = rng.choice(["active", "blocked", "closed"], size=n, p=[0.95, 0.03, 0.02])

    with conn.cursor() as cur, cur.copy(_COPY_SQL) as copy:
        for i in range(n):
            is_company = pyrand.random() < 0.10
            doc = _DIGITS.sub("", fake.cnpj() if is_company else fake.cpf())
            name = fake.company() if is_company else fake.name()
            account_number = f"{pyrand.randint(1, 9999):04d}-{pyrand.randint(0, 9)}"
            copy.write_row((
                account_number,
                str(codes[inst_idx[i]]),
                doc,
                name,
                str(acc_types[i]),
                str(statuses[i]),
            ))
    conn.commit()
    log(logger, "seed.accounts", count=n)
    return n


def fetch_account_ids(conn: psycopg.Connection) -> list[str]:
    """IDs das contas para amostragem em `transactions`."""
    with conn.cursor() as cur:
        cur.execute("SELECT id FROM accounts")
        return [str(row[0]) for row in cur.fetchall()]

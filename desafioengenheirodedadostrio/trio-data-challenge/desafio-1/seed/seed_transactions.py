"""Carga de 10M+ transações via COPY, em lotes, ordenadas por created_at.

Estratégia de performance:
  - distribuições geradas vetorizadas (numpy) por lote;
  - `id`/`external_id`/`currency`/`metadata` ficam de fora do COPY → o servidor
    aplica os DEFAULTs (gen_random_uuid, 'BRL', '{}'), reduzindo a largura do COPY
    e tirando a geração de UUID do laço Python;
  - formato TEXT do COPY montado com `\t`/`\n` (os campos não contêm esses
    caracteres), gravado em blocos — ordem de magnitude mais rápido que INSERT.
"""
from __future__ import annotations

import numpy as np
import psycopg

from config import Config, log
from generators import (
    generate_timestamps,
    inst_codes_weights,
    make_rng,
    sample_amounts,
    sample_status,
    sample_types,
    settlement_epoch,
)

_COPY_SQL = (
    "COPY transactions (amount, status, type, source_institution, "
    "destination_institution, source_account_id, destination_account_id, "
    "created_at, settled_at) FROM STDIN"
)


def _iso(epoch_seconds: np.ndarray) -> np.ndarray:
    """Array de epoch (s) -> array de strings ISO 'YYYY-MM-DDTHH:MM:SS' (UTC naive)."""
    dt64 = np.datetime64("1970-01-01T00:00:00") + epoch_seconds.astype("timedelta64[s]")
    return np.datetime_as_string(dt64, unit="s")


def run(conn: psycopg.Connection, cfg: Config, logger, account_ids: list[str]) -> int:
    rng, _ = make_rng(cfg.rng_seed + 1)
    n = cfg.seed_tx
    codes, weights = inst_codes_weights()
    probs = weights / weights.sum()
    accounts = np.array(account_ids)

    created = generate_timestamps(rng, n, cfg.end_date, cfg.window_days)

    written = 0
    with conn.cursor() as cur, cur.copy(_COPY_SQL) as copy:
        for start in range(0, n, cfg.batch):
            end = min(start + cfg.batch, n)
            m = end - start
            c_ep = created[start:end]

            types = sample_types(rng, m)
            status = sample_status(rng, m)
            amounts = sample_amounts(rng, m, types)
            settled, settled_mask = settlement_epoch(rng, m, types, status, c_ep)

            src_inst = codes[rng.choice(len(codes), size=m, p=probs)]
            dst_inst = codes[rng.choice(len(codes), size=m, p=probs)]
            src_acct = accounts[rng.integers(0, len(accounts), size=m)]
            dst_acct = accounts[rng.integers(0, len(accounts), size=m)]

            amount_s = np.char.mod("%.2f", amounts)
            created_s = _iso(c_ep)
            settled_s = _iso(np.where(settled_mask, settled, 0))

            lines = []
            append = lines.append
            for i in range(m):
                settled_field = settled_s[i] + "+00" if settled_mask[i] else r"\N"
                append(
                    f"{amount_s[i]}\t{status[i]}\t{types[i]}\t"
                    f"{src_inst[i]}\t{dst_inst[i]}\t{src_acct[i]}\t{dst_acct[i]}\t"
                    f"{created_s[i]}+00\t{settled_field}"
                )
            copy.write("\n".join(lines) + "\n")

            written += m
            log(logger, "seed.transactions.batch", written=written, total=n)

    conn.commit()
    log(logger, "seed.transactions", count=written)
    return written

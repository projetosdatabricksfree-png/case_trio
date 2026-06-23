"""Loader do ClickHouse (trio_analytics.transactions) via clickhouse-connect.

Reusa generators.py — MESMA SSOT de distribuições do seed do TimescaleDB (tipos,
status, valores log-normais, timestamps sazonais, latência de liquidação por tipo).
Insere por COLUNAS em lotes (column-oriented). `id`/`external_id`/`currency` ficam
fora do INSERT (DEFAULT no servidor). `version` = updated_at (settled_at se houver,
senão created_at) — desempate do ReplacingMergeTree.
"""
from __future__ import annotations

import uuid

import numpy as np
import pandas as pd

from ch_config import ClickHouseConfig
from config import log
from generators import (
    generate_timestamps,
    inst_codes_weights,
    make_rng,
    sample_amounts,
    sample_status,
    sample_types,
    settlement_epoch,
)

_EPOCH_MS = np.datetime64("1970-01-01T00:00:00", "ms")
_NAT = np.datetime64("NaT", "ms")


def _to_dt64ms(epoch_seconds: np.ndarray) -> np.ndarray:
    """Epoch (s) -> numpy datetime64[ms] (clickhouse-connect mapeia p/ DateTime64(3))."""
    return _EPOCH_MS + (epoch_seconds.astype(np.int64) * 1000).astype("timedelta64[ms]")


def _account_pool(n: int, seed: int) -> np.ndarray:
    """Pool de account-UUIDs (object ndarray) — evita gerar UUID por linha na carga."""
    r = np.random.default_rng(seed)
    raw = r.integers(0, 256, size=(n, 16), dtype=np.uint8)
    return np.array([uuid.UUID(bytes=bytes(raw[i])) for i in range(n)], dtype=object)


def run(client, cfg: ClickHouseConfig, logger) -> int:
    rng, _ = make_rng(cfg.rng_seed + 1)
    n = cfg.seed_tx
    codes, weights = inst_codes_weights()
    probs = weights / weights.sum()
    codes_list = codes.tolist()

    pool = _account_pool(cfg.accounts, cfg.rng_seed)
    created = generate_timestamps(rng, n, cfg.end_date, cfg.window_days)

    table = f"{cfg.database}.transactions"
    written = 0
    for start in range(0, n, cfg.batch):
        end = min(start + cfg.batch, n)
        m = end - start
        c_ep = created[start:end]

        types = sample_types(rng, m)
        status = sample_status(rng, m)
        amounts = sample_amounts(rng, m, types)
        settled, settled_mask = settlement_epoch(rng, m, types, status, c_ep)

        src_idx = rng.choice(len(codes), size=m, p=probs)
        dst_idx = rng.choice(len(codes), size=m, p=probs)
        src_inst = [codes_list[i] for i in src_idx]
        dst_inst = [codes_list[i] for i in dst_idx]
        src_acct = pool[rng.integers(0, len(pool), size=m)].tolist()
        dst_acct = pool[rng.integers(0, len(pool), size=m)].tolist()

        created_dt = _to_dt64ms(c_ep)
        settled_all = _to_dt64ms(np.where(settled_mask, settled, c_ep))
        settled_dt = np.where(settled_mask, settled_all, _NAT)
        version_dt = np.where(settled_mask, settled_all, created_dt)

        # DataFrame por lote -> insert_df: clickhouse-connect escreve datetime64/NaT
        # de forma vetorizada (rápido p/ 100M) e mapeia NaT -> NULL no settled_at.
        # id/external_id/currency ausentes do df -> DEFAULT no servidor.
        df = pd.DataFrame({
            "amount": amounts,                  # Decimal(18,2) <- float64 (2 casas)
            "status": status,
            "type": types,
            "source_institution": src_inst,
            "destination_institution": dst_inst,
            "source_account_id": src_acct,
            "destination_account_id": dst_acct,
            "created_at": created_dt,
            "settled_at": settled_dt,
            "version": version_dt,
        })
        client.insert_df(table, df)
        written += m
        log(logger, "seed.clickhouse.batch", written=written, total=n)

    return written

"""Configuração do loader do ClickHouse (trio_analytics).

Espelha legacy_config.py: conexão + escala vêm de env (defaults de dev). O loader
reusa generators.py — a escala (CH_SEED_TX) é independente do seed do TimescaleDB.
"""
from __future__ import annotations

import os
from dataclasses import dataclass
from datetime import date


@dataclass(frozen=True)
class ClickHouseConfig:
    host: str
    port: int          # porta HTTP (clickhouse-connect)
    database: str
    user: str
    password: str
    seed_tx: int       # nº de transações a gerar (default modesto; suba p/ o headline)
    batch: int         # tamanho do lote de INSERT
    accounts: int      # tamanho do pool de account-UUIDs
    rng_seed: int
    window_days: int
    end_date: date


def load_ch_config() -> ClickHouseConfig:
    return ClickHouseConfig(
        host=os.getenv("CH_HOST", "clickhouse"),
        port=int(os.getenv("CH_HTTP_PORT", "8123")),
        database=os.getenv("CH_DATABASE", "trio_analytics"),
        user=os.getenv("CLICKHOUSE_USER", "trio"),
        password=os.getenv("CLICKHOUSE_PASSWORD", "trio2024"),
        seed_tx=int(os.getenv("CH_SEED_TX", "5000000")),
        batch=int(os.getenv("CH_SEED_BATCH", "1000000")),
        accounts=int(os.getenv("CH_SEED_ACCOUNTS", "50000")),
        rng_seed=int(os.getenv("RNG_SEED", "42")),
        window_days=int(os.getenv("SEED_WINDOW_DAYS", "365")),
        end_date=date.fromisoformat(os.getenv("SEED_END_DATE", "2026-06-21")),
    )

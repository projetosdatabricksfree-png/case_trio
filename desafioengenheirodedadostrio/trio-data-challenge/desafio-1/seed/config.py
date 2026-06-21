"""Configuração e logging estruturado (JSON) do seeder.

Sem credenciais hardcoded: tudo vem de variáveis de ambiente (injetadas pelo
docker-compose a partir do .env), com defaults de desenvolvimento.
"""
from __future__ import annotations

import json
import logging
import os
import sys
from dataclasses import dataclass, asdict
from datetime import date, datetime, timezone


# ---------------------------------------------------------------------------
# Logging estruturado (uma linha JSON por evento) — convenção do projeto.
# ---------------------------------------------------------------------------
class _JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        payload = {
            "ts": datetime.now(timezone.utc).isoformat(),
            "level": record.levelname,
            "event": record.getMessage(),
        }
        fields = getattr(record, "extra_fields", None)
        if fields:
            payload.update(fields)
        return json.dumps(payload, default=str)


def get_logger(name: str = "seeder") -> logging.Logger:
    logger = logging.getLogger(name)
    if not logger.handlers:
        handler = logging.StreamHandler(sys.stdout)
        handler.setFormatter(_JsonFormatter())
        logger.addHandler(handler)
        logger.setLevel(logging.INFO)
        logger.propagate = False
    return logger


def log(logger: logging.Logger, event: str, **fields) -> None:
    """Emite um evento JSON com campos arbitrários."""
    logger.info(event, extra={"extra_fields": fields})


# ---------------------------------------------------------------------------
# Configuração
# ---------------------------------------------------------------------------
@dataclass(frozen=True)
class Config:
    host: str
    port: int
    dbname: str
    user: str
    password: str
    seed_tx: int           # nº de transações a gerar (alvo: 10_000_000)
    seed_accounts: int     # nº de contas (dimensão)
    rng_seed: int          # semente do RNG (reprodutibilidade)
    batch: int             # tamanho do lote de COPY
    recon_rate: float      # fração de transações com evento de conciliação
    mismatch_rate: float   # fração dos eventos de conciliação que divergem
    window_days: int       # janela temporal (12 meses ~ 365 dias)
    end_date: date         # último dia da janela

    @property
    def conninfo(self) -> str:
        return (
            f"host={self.host} port={self.port} dbname={self.dbname} "
            f"user={self.user} password={self.password}"
        )

    def public(self) -> dict:
        """Config sem segredos, para logar no início do run."""
        d = asdict(self)
        d.pop("password", None)
        return d


def load_config() -> Config:
    return Config(
        host=os.getenv("PGHOST", "timescaledb"),
        port=int(os.getenv("PGPORT", "5432")),
        dbname=os.getenv("PGDATABASE", "trio_transactions"),
        user=os.getenv("POSTGRES_USER", "trio"),
        password=os.getenv("POSTGRES_PASSWORD", "trio2024"),
        seed_tx=int(os.getenv("SEED_TX", "10000000")),
        seed_accounts=int(os.getenv("SEED_ACCOUNTS", "50000")),
        rng_seed=int(os.getenv("RNG_SEED", "42")),
        batch=int(os.getenv("SEED_BATCH", "500000")),
        recon_rate=float(os.getenv("SEED_RECON_RATE", "0.2")),
        mismatch_rate=float(os.getenv("SEED_MISMATCH_RATE", "0.03")),
        window_days=int(os.getenv("SEED_WINDOW_DAYS", "365")),
        end_date=date.fromisoformat(os.getenv("SEED_END_DATE", "2026-06-21")),
    )

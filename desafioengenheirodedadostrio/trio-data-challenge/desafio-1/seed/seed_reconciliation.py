"""Carga de `reconciliation_events` para um subconjunto das transações.

Garante casos divergentes (difference > 0,01) para a Q2 da Sprint 02. Usa um
cursor server-side (streaming) para varrer transactions sem carregar tudo em
memória, mantendo um lote a cada `keep_every` linhas para atingir `recon_rate`.
Conexões de leitura e escrita são separadas (uma varre, a outra faz COPY).
"""
from __future__ import annotations

import random

import psycopg

from config import Config, log

_COPY_SQL = (
    "COPY reconciliation_events (transaction_id, transaction_created_at, "
    "event_type, external_reference, amount_expected, amount_received, notes) "
    "FROM STDIN"
)
_FLUSH = 100_000


def run(cfg: Config, logger) -> int:
    if cfg.recon_rate <= 0:
        return 0
    keep_every = max(1, round(1 / cfg.recon_rate))
    rnd = random.Random(cfg.rng_seed + 7)

    written = 0
    buffer: list[str] = []
    read_conn = psycopg.connect(cfg.conninfo)
    write_conn = psycopg.connect(cfg.conninfo)
    try:
        with read_conn.cursor(name="recon_src") as src, write_conn.cursor() as wcur:
            src.itersize = 50_000
            src.execute("SELECT id, created_at, amount FROM transactions")
            with wcur.copy(_COPY_SQL) as copy:
                for i, (tx_id, tx_created, amount) in enumerate(src):
                    if i % keep_every:
                        continue
                    amount_f = float(amount)
                    roll = rnd.random()
                    if roll < cfg.mismatch_rate:
                        event_type = "mismatch"
                        delta = round(rnd.uniform(0.01, amount_f * 0.05 + 0.02), 2)
                        sign = 1 if rnd.random() < 0.5 else -1
                        received = max(0.01, round(amount_f + sign * delta, 2))
                        notes = "valor divergente"
                    elif roll < cfg.mismatch_rate + 0.010:
                        event_type = "missing"
                        received = 0.0
                        notes = "contrapartida ausente"
                    elif roll < cfg.mismatch_rate + 0.015:
                        event_type = "duplicate"
                        received = amount_f
                        notes = "evento duplicado"
                    else:
                        event_type = "match"
                        received = amount_f
                        notes = r"\N"

                    buffer.append(
                        f"{tx_id}\t{tx_created.isoformat()}\t{event_type}\t"
                        f"EXT-{i:012d}\t{amount_f:.2f}\t{received:.2f}\t{notes}"
                    )
                    if len(buffer) >= _FLUSH:
                        copy.write("\n".join(buffer) + "\n")
                        written += len(buffer)
                        buffer.clear()
                        log(logger, "seed.reconciliation.batch", written=written)

                if buffer:
                    copy.write("\n".join(buffer) + "\n")
                    written += len(buffer)
        write_conn.commit()
    finally:
        read_conn.close()
        write_conn.close()

    log(logger, "seed.reconciliation", count=written)
    return written

"""Carga da dimensão `institutions` (SSOT)."""
from __future__ import annotations

import psycopg

from config import Config, log
from institutions import INSTITUTIONS

_COPY_SQL = (
    "COPY institutions (institution_code, name, short_name, type) FROM STDIN"
)


def run(conn: psycopg.Connection, cfg: Config, logger) -> int:
    rows = [(code, name, short, typ) for (code, name, short, typ, _w) in INSTITUTIONS]
    with conn.cursor() as cur, cur.copy(_COPY_SQL) as copy:
        for row in rows:
            copy.write_row(row)
    conn.commit()
    log(logger, "seed.institutions", count=len(rows))
    return len(rows)

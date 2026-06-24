"""Logging estruturado (uma linha JSON por evento) — convenção do projeto.

Mesmo formato do seeder (desafio-1/seed/config.py): a imagem do pipeline é
separada e não importa de lá, então o padrão é replicado aqui, autocontido.
"""
from __future__ import annotations

import json
import logging
import sys
from datetime import datetime, timezone


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


def get_logger(name: str = "pipeline") -> logging.Logger:
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

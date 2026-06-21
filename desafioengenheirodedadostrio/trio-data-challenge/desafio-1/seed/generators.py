"""Geração vetorizada (numpy) das distribuições realistas do seed.

Todas as funções recebem um numpy Generator semeado para reprodutibilidade.
A vetorização é o que viabiliza gerar 10M de linhas em janela aceitável.
"""
from __future__ import annotations

import random
from datetime import date, datetime, timedelta, timezone

import numpy as np

from institutions import INSTITUTIONS

# --- Mix por tipo (Pix domina; cartão > TED > boleto) -----------------------
TYPES = np.array(["pix", "ted", "boleto", "card"])
TYPE_P = np.array([0.70, 0.10, 0.05, 0.15])

# --- Mix de status (maioria liquidada) --------------------------------------
STATUS = np.array(["settled", "pending", "failed", "reversed"])
STATUS_P = np.array([0.90, 0.05, 0.03, 0.02])

# --- Sazonalidade: dias úteis e horário comercial concentram o volume -------
# Pesos por dia da semana (Segunda=0 .. Domingo=6).
WEEKDAY_W = np.array([1.05, 1.05, 1.05, 1.05, 1.10, 0.45, 0.30])
# Pesos por hora do dia (vale de madrugada, pico comercial).
HOUR_W = np.array([
    0.20, 0.10, 0.08, 0.06, 0.06, 0.10, 0.30, 0.60,
    0.90, 1.00, 1.00, 0.95, 0.90, 0.95, 1.00, 1.00,
    0.95, 0.90, 0.80, 0.70, 0.60, 0.50, 0.40, 0.30,
])

# --- Valor: log-normal por tipo (TED/boleto maiores; Pix menores) -----------
TYPE_AMOUNT_FACTOR = {"pix": 1.0, "ted": 8.0, "boleto": 5.0, "card": 1.6}

# --- Latência de liquidação por tipo (segundos; min, max) -------------------
TYPE_LATENCY = {
    "pix": (1, 30),
    "card": (2, 120),
    "ted": (300, 7200),
    "boleto": (600, 86400),
}


def make_rng(seed: int) -> tuple[np.random.Generator, random.Random]:
    return np.random.default_rng(seed), random.Random(seed)


def inst_codes_weights() -> tuple[np.ndarray, np.ndarray]:
    codes = np.array([row[0] for row in INSTITUTIONS])
    weights = np.array([row[4] for row in INSTITUTIONS], dtype=float)
    return codes, weights


def generate_timestamps(rng: np.random.Generator, n: int, end_date: date,
                        window_days: int) -> np.ndarray:
    """Epoch (s, UTC) de `n` transações na janela, ORDENADO ascendentemente.

    Carregar ordenado por created_at melhora a compressão e a localidade de
    chunk no TimescaleDB.
    """
    start_dt = (datetime(end_date.year, end_date.month, end_date.day, tzinfo=timezone.utc)
                - timedelta(days=window_days - 1))
    start_epoch = int(start_dt.timestamp())

    weekday_of_day = np.array(
        [(start_dt + timedelta(days=int(i))).weekday() for i in range(window_days)]
    )
    day_w = WEEKDAY_W[weekday_of_day]
    day_p = day_w / day_w.sum()
    hour_p = HOUR_W / HOUR_W.sum()

    days = rng.choice(window_days, size=n, p=day_p)
    hours = rng.choice(24, size=n, p=hour_p)
    minutes = rng.integers(0, 60, size=n)
    seconds = rng.integers(0, 60, size=n)

    epoch = start_epoch + days * 86400 + hours * 3600 + minutes * 60 + seconds
    epoch.sort()
    return epoch.astype(np.int64)


def sample_types(rng: np.random.Generator, n: int) -> np.ndarray:
    return TYPES[rng.choice(4, size=n, p=TYPE_P)]


def sample_status(rng: np.random.Generator, n: int) -> np.ndarray:
    return STATUS[rng.choice(4, size=n, p=STATUS_P)]


def sample_amounts(rng: np.random.Generator, n: int, types: np.ndarray) -> np.ndarray:
    """Valores log-normais (muitas pequenas, cauda de grandes), escalados por tipo."""
    base = rng.lognormal(mean=4.2, sigma=1.0, size=n)
    factor = np.ones(n)
    for t, f in TYPE_AMOUNT_FACTOR.items():
        factor[types == t] = f
    return np.clip(np.round(base * factor, 2), 1.0, 9_999_999.99)


def settlement_epoch(rng: np.random.Generator, n: int, types: np.ndarray,
                     status: np.ndarray, created_epoch: np.ndarray
                     ) -> tuple[np.ndarray, np.ndarray]:
    """Retorna (settled_epoch, settled_mask).

    settled_at existe para 'settled'/'reversed' (created + latência por tipo) e é
    NULL para 'pending'/'failed'.
    """
    settled_mask = (status == "settled") | (status == "reversed")
    latency = np.zeros(n, dtype=np.int64)
    for t, (lo, hi) in TYPE_LATENCY.items():
        mask = types == t
        latency[mask] = rng.integers(lo, hi, size=int(mask.sum()))
    settled = np.where(settled_mask, created_epoch + latency, -1)
    return settled, settled_mask

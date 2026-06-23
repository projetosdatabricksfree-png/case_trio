"""Configuração e dados de referência do seed do LEGADO (trio_legado).

Reaproveita a SSOT `institutions.py` (mesma usada pelo seed do TimescaleDB) para
DERIVAR, de forma determinística, as configurações operacionais por instituição e
as parcerias. Mantém UMA fonte de instituições para todo o projeto — o legado é um
banco separado, então a referência é duplicada fisicamente, nunca na origem.
"""
from __future__ import annotations

import json
import os
from dataclasses import dataclass

import numpy as np

from institutions import INSTITUTIONS

# ---------------------------------------------------------------------------
# Parâmetros do seed do legado (env + defaults de desenvolvimento).
# Default modesto (dezenas de milhares) → roda em segundos no CI, sem split.
# ---------------------------------------------------------------------------
@dataclass(frozen=True)
class LegacyConfig:
    users: int
    accounts_per_user: float
    rng_seed: int


def load_legacy_config() -> LegacyConfig:
    return LegacyConfig(
        users=int(os.getenv("SEED_USERS", "30000")),
        accounts_per_user=float(os.getenv("SEED_ACCOUNTS_PER_USER", "1.3")),
        rng_seed=int(os.getenv("RNG_SEED", "42")),
    )


# ---------------------------------------------------------------------------
# Derivação determinística de institution_configs a partir da SSOT.
# settlement_window por tipo dá um spread real (bancos liquidam D+0; PIs/coops
# D+1; fintechs D+2) — a Story 3.3 filtra D+1, então PIs/coops casam.
# ---------------------------------------------------------------------------
_SETTLEMENT_BY_TYPE = {
    "bank": "D+0",
    "payment_institution": "D+1",
    "credit_union": "D+1",
    "fintech": "D+2",
}

_FEE_BY_TYPE = {
    "bank":                {"pix": 0.0, "ted": 8.5, "boleto": 2.9, "card_pct": 0.018},
    "payment_institution": {"pix": 0.0, "ted": 5.0, "boleto": 3.5, "card_pct": 0.022},
    "fintech":             {"pix": 0.0, "ted": 4.0, "boleto": 1.9, "card_pct": 0.015},
    "credit_union":        {"pix": 0.0, "ted": 6.0, "boleto": 2.5, "card_pct": 0.016},
}

# Linhas "legadas" desativadas → tornam o filtro `active` da Story 3.3 significativo.
_INACTIVE_SHORT = {"InterLeg", "C6Cons"}


def configs_rows() -> list[tuple]:
    """Linhas para COPY em institution_configs (uma por instituição da SSOT)."""
    rows = []
    for code, name, short, typ, weight in INSTITUTIONS:
        rows.append((
            code,
            name,
            short,
            typ,
            _SETTLEMENT_BY_TYPE[typ],
            json.dumps(_FEE_BY_TYPE[typ]),
            f"https://api.{short.lower()}.example.com/v1",
            weight * 100_000,                       # max_tx_per_day ~ porte
            typ != "credit_union",                  # supports_pix
            short not in _INACTIVE_SHORT,            # active
        ))
    return rows


def partners_rows(rng: np.random.Generator) -> list[tuple]:
    """Linhas para COPY em institution_partners (1–3 por instituição).

    `id` é IDENTITY (gerado pelo servidor) → fora do COPY.
    """
    types = np.array(["acquirer", "issuer", "correspondent"])
    statuses = np.array(["active", "suspended", "terminated"])
    status_p = np.array([0.85, 0.10, 0.05])

    rows = []
    for code, _name, short, _typ, _w in INSTITUTIONS:
        n_partners = int(rng.integers(1, 4))
        for k in range(n_partners):
            rows.append((
                code,
                f"{short} Partner {k + 1}",
                str(types[k % len(types)]),
                str(rng.choice(statuses, p=status_p)),
                round(float(rng.uniform(0.001, 0.05)), 4),
            ))
    return rows

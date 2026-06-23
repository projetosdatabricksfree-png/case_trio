"""API do Desafio 1 / Parte C (RF-3.5) — FastAPI servindo o ClickHouse.

Demonstra o ClickHouse servindo APLICAÇÃO (não só dashboard):
  - GET /transactions/volume/realtime  -> volume agregado recente (painel de ops)
  - GET /institutions/{code}/health    -> saúde por instituição (regra de negócio),
                                          nome enriquecido pelo dictionary (dictGet)

Janela ancorada a max(created_at) (o seed é estático) para sempre retornar dados.
Queries PARAMETRIZADAS (binders {name:Type} do clickhouse-connect) — sem string
interpolation, sem SQL injection. Sem credenciais hardcoded (tudo via env).
"""
from __future__ import annotations

import os
from functools import lru_cache

import clickhouse_connect
from clickhouse_connect.driver.exceptions import ClickHouseError
from fastapi import FastAPI, HTTPException, Query

app = FastAPI(
    title="Trio — ClickHouse Realtime API",
    version="1.0.0",
    description="Volume transacional e saúde por instituição, em tempo real, do ClickHouse.",
)

_DATABASE = os.getenv("CH_DATABASE", "trio_analytics")


@lru_cache(maxsize=1)
def get_client():
    """Cliente clickhouse-connect (lazy + cacheado): não toca o ClickHouse no import,
    então /health responde mesmo antes de o schema/carga existirem."""
    return clickhouse_connect.get_client(
        host=os.getenv("CH_HOST", "clickhouse"),
        port=int(os.getenv("CH_HTTP_PORT", "8123")),
        username=os.getenv("CLICKHOUSE_USER", "trio"),
        password=os.getenv("CLICKHOUSE_PASSWORD", "trio2024"),
        database=_DATABASE,
        connect_timeout=5,
        send_receive_timeout=30,
    )


def _query(sql: str, params: dict):
    try:
        return get_client().query(sql, parameters=params)
    except ClickHouseError as exc:
        raise HTTPException(status_code=503, detail=f"clickhouse error: {exc}") from exc
    except Exception as exc:  # conexão/timeout
        raise HTTPException(status_code=503, detail=f"clickhouse unavailable: {exc}") from exc


@app.get("/health")
def health() -> dict:
    """Liveness — não consulta o ClickHouse (probe do compose)."""
    return {"status": "ok"}


@app.get("/transactions/volume/realtime")
def volume_realtime(
    window_minutes: int = Query(5, ge=1, le=1440, description="Janela em minutos"),
) -> dict:
    """Volume transacional agregado na janela recente (painel de operações)."""
    res = _query(
        f"""
        WITH (SELECT max(created_at) FROM {_DATABASE}.transactions) AS t_max
        SELECT
            type,
            count()              AS tx,
            round(sum(amount), 2) AS sum_amount
        FROM {_DATABASE}.transactions
        WHERE created_at > t_max - INTERVAL {{win:UInt32}} MINUTE
        GROUP BY type
        ORDER BY tx DESC
        """,
        {"win": window_minutes},
    )
    by_type = [
        {"type": t, "count": int(c), "sum_amount": float(s)}
        for (t, c, s) in res.result_rows
    ]
    asof = _query(f"SELECT max(created_at) FROM {_DATABASE}.transactions", {})
    return {
        "window_minutes": window_minutes,
        "as_of": str(asof.result_rows[0][0]) if asof.result_rows else None,
        "count": sum(r["count"] for r in by_type),
        "sum_amount": round(sum(r["sum_amount"] for r in by_type), 2),
        "by_type": by_type,
    }


@app.get("/institutions/{code}/health")
def institution_health(
    code: str,
    window_minutes: int = Query(60, ge=1, le=10080, description="Janela em minutos"),
) -> dict:
    """Saúde recente de uma instituição (taxa de sucesso/falha). Nome via dictGet."""
    res = _query(
        f"""
        WITH (SELECT max(created_at) FROM {_DATABASE}.transactions) AS t_max
        SELECT
            dictGet('{_DATABASE}.dict_institutions', 'institution_name', {{code:String}}) AS name,
            count()                       AS total,
            countIf(status = 'settled')   AS settled,
            countIf(status = 'failed')    AS failed
        FROM {_DATABASE}.transactions
        WHERE source_institution = {{code:String}}
          AND created_at > t_max - INTERVAL {{win:UInt32}} MINUTE
        """,
        {"code": code, "win": window_minutes},
    )
    name, total, settled, failed = res.result_rows[0]
    total = int(total)
    if total == 0:
        raise HTTPException(
            status_code=404,
            detail=f"sem transações p/ a instituição '{code}' na janela de {window_minutes}min",
        )
    return {
        "code": code,
        "name": name or None,
        "window_minutes": window_minutes,
        "total": total,
        "settled": int(settled),
        "failed": int(failed),
        "success_rate": round(int(settled) / total, 4),
        "failure_rate": round(int(failed) / total, 4),
    }

# =============================================================================
#  API do Desafio 1 / Parte C — FastAPI + Uvicorn servindo o ClickHouse.
#  Demonstra o ClickHouse servindo APLICAÇÃO (não só dashboard): volume em tempo
#  real e saúde por instituição, em JSON. Sobe no `docker compose up` (porta 8000).
# =============================================================================
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY . ./

EXPOSE 8000
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]

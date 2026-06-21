# =============================================================================
#  Seeder do Desafio 1 — gerador/carga de dados sintéticos do TimescaleDB.
#  Imagem one-shot, executada via `docker compose --profile tools run --rm seeder`
#  (alvo `make seed`). Containerizado para reprodutibilidade total: o avaliador
#  não precisa de Python no host.
# =============================================================================
FROM python:3.12-slim

# Evita .pyc e garante logs sem buffer (JSON em stdout aparece em tempo real).
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY . ./

CMD ["python", "run.py"]

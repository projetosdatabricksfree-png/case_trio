# ADR-0001 — Versionamento das imagens Docker

- **Status:** Aceito
- **Data:** 2026-06-21
- **Contexto:** Sprint 00 (Foundation)
- **Decisores:** Engenharia de Dados

## Contexto

O ambiente do desafio é entregue via `docker-compose.yml` com quatro serviços. O escopo
(§2.2 "Ambiente Fornecido") especifica as versões a usar e, em particular, define o
ClickHouse como **`latest`**. Imagens `latest` (e tags móveis como `latest-pg16`) não são
reprodutíveis: o digest por trás da tag pode mudar entre dois `docker compose pull`, o que
em produção é uma fonte clássica de "funcionava ontem".

Precisamos conciliar **fidelidade ao escopo** (usar as versões pedidas) com
**reprodutibilidade** (saber exatamente o que foi avaliado).

## Decisão

1. **No ambiente do desafio**, seguimos o escopo §2.2 literalmente:
   - `timescale/timescaledb:latest-pg16`
   - `postgres:16-bookworm`
   - `clickhouse/clickhouse-server:latest`
   - `grafana/grafana:latest`
2. **Capturamos o digest** efetivamente usado **no momento da entrega**, para que o estado
   avaliado seja reproduzível:
   ```bash
   docker compose pull
   docker compose images          # mostra IMAGE / TAG / DIGEST de cada serviço
   ```
   O workflow `release.yml` automatiza essa captura e publica o manifesto de digests como
   artifact da release.
3. **Pinagem por digest fica como recomendação de produção** (AWS), não aplicada agora — ver abaixo.

## Consequências

- ✅ Entrega fiel ao escopo e ao mesmo tempo auditável (digest registrado).
- ✅ O smoke test + CI provam que o ambiente sobe com as imagens vigentes a cada push.
- ⚠️ Entre a captura do digest e uma nova execução, um `pull` pode trazer imagem diferente;
  por isso o digest da entrega é o ponto de referência.

## Recomendação para produção (AWS)

- **Pinar por digest** (`image: clickhouse/clickhouse-server@sha256:...`) ou usar tags
  imutáveis versionadas, promovidas por ambiente (dev → staging → prod).
- Espelhar imagens em um **registry privado** (ECR) com varredura de vulnerabilidades.
- Atualizações controladas por **Dependabot** (`docker`) + revisão, nunca `latest` em prod.

> Relacionado: política de segredos e operação ficam no runbook (Sprint 06).

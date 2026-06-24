# Checklist de validação end-to-end

> Sprint 07 · Story 7.4. Prova de que **tudo sobe e roda do zero**. Cada critério mínimo de aceitação
> do desafio mapeia para um **comando local**, um **resultado esperado** e o **passo de CI que o
> prova** automaticamente a cada push. O job `integration` (`.github/workflows/ci.yml`) executa esta
> sequência inteira a partir de um ambiente limpo (`docker compose down -v` no `always()`), então a
> validação não depende de execução manual.

## Como rodar a validação completa (local)

A mesma ordem do CI; smoke seed (~20k) para velocidade. Troque por `make seed` / `make seed-ch` para
volume cheio.

```bash
cd desafioengenheirodedadostrio/trio-data-challenge
make reset                                   # down -v -> up --wait -> smoke (ambiente limpo)
make migrate seed-smoke index sanity         # TimescaleDB: schema + seed + índices + sanidade
make index-s2 caggs policies queries         # CAggs, políticas, Q1–Q4 (EXPLAIN antes/depois)
make migrate-legado seed-legado index-legado analyze-legado queries-legado
make migrate-ch seed-ch-smoke queries-ch optimize-ch
make migrate-pipeline pipeline-once pipeline-refs pipeline-mutation-demo
make backup recovery-demo runbook-storage-check
make incident-demo                           # incidente SEV-1: volume zero -> resolução -> CH == TS
```

## Matriz: critério → comando → prova no CI

| # | Critério de aceitação | Comando local | Resultado esperado | Passo de CI que prova |
|---|---|---|---|---|
| 1 | Ambiente sobe sem erros | `make up` | 6 serviços `healthy` | **Bring up the stack (wait for healthy)** + **Smoke test** |
| 2 | Seed popula com volume relevante | `make seed` / `seed-smoke` + `make sanity` | 10M (ou ≥15k smoke); Pix dominante, 4 tipos | **Schema + seed smoke** (assert tx/types/divergências) |
| 3 | Queries D1 com `EXPLAIN ANALYZE` documentado | `make queries` | Q1–Q4 retornam; ganhos no `REPORT.md` | **Sprint 02 — CAggs, políticas & queries** (CAggs materializaram) |
| 4 | Migração PostgreSQL → Aurora/RDS fundamentada | leitura `migration-analysis.md` | opções + matriz + runbook 72h + rollback | **Sprint 03 — Legado** (schema/seed/queries, FK coerente) |
| 5 | Dashboard + API consultando ClickHouse | `make queries-ch` + `curl :8000/...` | flagship sub-segundo; API retorna JSON | **Sprint 04 — ClickHouse** (MVs, dictGet, dedup, API JSON) |
| 6 | Pipeline TimescaleDB → ClickHouse end-to-end | `make pipeline-once` (2×) + `pipeline-mutation-demo` | idempotente (count `FINAL` estável); mutação sem duplicar; DLQ | **Sprint 05 — Pipelines** (idempotência, refs, DLQ) |
| 7 | Dashboard Grafana funcional + backup/recovery | `make backup recovery-demo` + Grafana :3000 | 3 artefatos; recovery `antes==depois`; 4 dashboards | **Sprint 06 — Ops & Observabilidade** (dashboards≥4, alerta≥1, 3 backups) |
| 8 | Documentação completa + repositório organizado | leitura READMEs/REPORTs/ADR | índice de entregáveis; docs consistentes | revisão Sprint 07 (cross-check) |
| 9 | Incidente SEV-1 respondido + reproduzível | `make incident-demo` | investigação + convergência `CH max == TS max` | **Sprint 07 — Incidente SEV-1** (assert CH==TS; doc presente) |

## Invariantes verificados ao vivo (não só "rodou")

- **Idempotência do pipeline:** `SELECT count() FROM transactions FINAL` não muda entre duas rodadas
  de `make pipeline-once`.
- **Recovery determinístico:** `janela_depois == janela_antes` **e** `total_depois == total_antes`.
- **Convergência do incidente:** `CH max(created_at) == TS max(created_at)` após a resolução.
- **Observabilidade provisionada:** `curl -su admin:admin :3000/api/search?type=dash-db | jq length`
  ≥ 4; `.../api/v1/provisioning/alert-rules | jq length` ≥ 1.
- **Sem segredos no repo:** gitleaks no CI; só `.env.example` versionado.

## Tempo de bootstrap (referência para a apresentação)

| Etapa | Tempo observado (smoke) |
|---|---|
| `make up` (6 serviços → healthy) | ~30–40 s |
| Seed smoke + migrações dos 3 bancos | ~30–60 s |
| Pipeline + ops + incidente | ~30–60 s |
| **Total do zero (ambiente demonstrável)** | **~2–3 min** (smoke) |

> Volume cheio: `make seed` (10M) ~10 min e `make seed-ch` (50M) ~9 min são as etapas longas — rodar
> **antes** da apresentação. Para a defesa ao vivo, o smoke seed já exercita todos os caminhos.

# Desafio 1 — Performance e Tuning de Queries

Banco transacional (**TimescaleDB**), legado (**PostgreSQL**) e motor analítico (**ClickHouse**):
modelagem, seed em escala, queries otimizadas e a API que serve o ClickHouse.

| Pasta / arquivo | Conteúdo | Preenchido em |
|---|---|---|
| `schemas/` | DDL: tabelas, hypertable, índices, engines | Sprints 01, 03, 04 |
| `seed/` | Geração e carga de dados sintéticos (COPY/batch) | Sprint 01 |
| `queries/` | Q1–Q4 com `EXPLAIN ANALYZE` antes/depois | Sprint 02 |
| `api/` | FastAPI servindo ClickHouse (RF-3.5, Parte C) | Sprint 04 |
| `migration-analysis.md` | Análise de migração do legado → Aurora/RDS | Sprint 03 |
| `REPORT.md` | Relatório técnico consolidado do Desafio 1 | Sprints 02/04 |

> Sprint 01 concluída: `schemas/` (DDL + hypertable) e `seed/` (gerador 10M via
> `COPY`) prontos — ver [`REPORT.md`](REPORT.md). `queries/` e `api/` entram nas
> Sprints 02 e 04.

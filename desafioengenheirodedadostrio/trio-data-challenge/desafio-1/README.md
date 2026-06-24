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

> Todas as partes entregues (Sprints 01–04): `schemas/` (DDL + hypertable + engines
> ClickHouse), `seed/` (gerador 10M via `COPY`), `queries/` (Q1–Q4 com `EXPLAIN`
> antes/depois) e `api/` (FastAPI servindo o ClickHouse) — detalhes no
> [`REPORT.md`](REPORT.md).

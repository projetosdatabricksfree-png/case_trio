# Roadmap de Sprints — Trio Data Challenge

Plano de execução das 8 sprints (00–07) mapeado ao prazo de **7 dias corridos**. Cada sprint é um documento dedicado, quebrado em **stories isoladas** desenhadas para o workflow per-story com `/compact` entre elas.

---

## Visão Geral

| Sprint | Título | Dia(s) | Peso na avaliação | Stories |
|---|---|---|---|---|
| [00](sprints/sprint-00-foundation.md) | Foundation & Infraestrutura | 1 (manhã) | Pré-requisito | 4 |
| [01](sprints/sprint-01-timescaledb-modeling.md) | TimescaleDB — Modelagem & Dados | 1–2 | Técnica (40%) | 5 |
| [02](sprints/sprint-02-timescaledb-queries.md) | TimescaleDB — Agregados, Políticas & Queries | 2–3 | Técnica (40%) | 6 |
| [03](sprints/sprint-03-postgresql-legado.md) | PostgreSQL Legado & Migração | 3 | Técnica + Arquitetura | 4 |
| [04](sprints/sprint-04-clickhouse.md) | ClickHouse — Motor de Dados | 3–4 | Técnica (40%) | 6 |
| [05](sprints/sprint-05-pipelines-arquitetura.md) | Pipelines & Arquitetura | 4–5 | Arquitetura (25%) | 6 |
| [06](sprints/sprint-06-ops-observabilidade.md) | Operação & Observabilidade | 5–6 | Operação (20%) | 6 |
| [07](sprints/sprint-07-incidente-entrega.md) | Incidente & Entrega | 7 | Comunicação (15%) | 5 |

**Total:** 42 stories.

---

## Fluxo de Dependências

```
Sprint 00 (foundation)
   │
   ├──► Sprint 01 (TimescaleDB modelagem + seed)
   │       │
   │       └──► Sprint 02 (CAggs, políticas, queries) ──┐
   │                                                     │
   ├──► Sprint 03 (PostgreSQL legado) ───────────────────┤
   │                                                     │
   └──► Sprint 04 (ClickHouse schema + MVs + API) ───────┤
                                                         │
                          Sprint 05 (pipelines) ◄────────┘
                          [depende de 01, 03 e 04]
                                 │
                                 └──► Sprint 06 (backup, recovery, observabilidade)
                                          │
                                          └──► Sprint 07 (incidente + entrega)
```

**Caminho crítico:** 00 → 01 → 02 → 05 → 06 → 07. As sprints 03 e 04 podem ser intercaladas mas 05 depende delas.

---

## Cronograma Sugerido (7 dias)

### Dia 1 — Fundação + TimescaleDB começa
- **Manhã:** Sprint 00 completa (ambiente sobe sem erros).
- **Tarde:** Sprint 01 stories 1.1–1.3 (schema, hypertable, início do seed).

### Dia 2 — TimescaleDB consolida
- **Manhã:** Sprint 01 stories 1.4–1.5 (seed 10M validado, accounts/reconciliation).
- **Tarde:** Sprint 02 stories 2.1–2.2 (continuous aggregates).

### Dia 3 — Queries + Legado + ClickHouse começa
- **Manhã:** Sprint 02 stories 2.3–2.6 (políticas, Q1–Q4, gapfill, LGPD).
- **Tarde:** Sprint 03 completa (legado + migração).

### Dia 4 — ClickHouse + Pipeline começa
- **Manhã:** Sprint 04 stories 4.1–4.4 (schema, MVs, dictionary, query Grafana).
- **Tarde:** Sprint 04 stories 4.5–4.6 (API) + Sprint 05 story 5.1 (desenho do pipeline).

### Dia 5 — Pipeline + Arquitetura
- **Manhã:** Sprint 05 stories 5.2–5.4 (pipeline principal, mutações, pipeline de referência).
- **Tarde:** Sprint 05 stories 5.5–5.6 (diagrama + ADR).

### Dia 6 — Operação
- **Manhã:** Sprint 06 stories 6.1–6.3 (backup, recovery, runbook storage).
- **Tarde:** Sprint 06 stories 6.4–6.6 (dashboards, alertas).

### Dia 7 — Incidente + Empacotamento
- **Manhã:** Sprint 07 stories 7.1–7.2 (resposta SEV-1, runbook review).
- **Tarde:** Sprint 07 stories 7.3–7.5 (README raiz, REPORTs finais, prep apresentação).

---

## Princípios de Execução (do skill token-economy)

1. **Uma story por sessão** quando possível. `/compact` entre stories preservando schemas, decisões e queries validadas.
2. **Sonnet por padrão.** Opus apenas para: ADR (5.6), análise de migração (3.4), runbook de storage (6.3), resposta a incidente (7.1).
3. **Referência cirúrgica.** Ao implementar, aponte `@sprints/sprint-0X.md` story Y — nunca carregue o repo inteiro.
4. **Plan Mode antes de cada story** não-trivial. Confirme abordagem antes de executar.
5. **Documentar incrementalmente.** Cada sprint gera seus artefatos de doc; não acumule tudo para o Dia 7.

---

## Mapa Sprint → Requisito → Critério de Aceitação

| Sprint | Requisitos (PRD) | Critério mínimo do desafio coberto |
|---|---|---|
| 00 | NFR (reprodutibilidade) | `docker-compose up -d` sem erros |
| 01 | RF-1.1 a RF-1.3 | Seed popula bancos com volume relevante |
| 02 | RF-1.4 a RF-1.8 | Queries D1 com `EXPLAIN ANALYZE` documentado |
| 03 | RF-2.1 a RF-2.3 | Análise migração PostgreSQL → Aurora fundamentada |
| 04 | RF-3.1 a RF-3.5 | (prepara) dashboard + API consultando ClickHouse |
| 05 | RF-4.1 a RF-4.6 | Pipeline TimescaleDB → ClickHouse end-to-end |
| 06 | RF-5.1 a RF-5.5 | Dashboard Grafana funcional + backup/recovery |
| 07 | RF-5.6 + entrega | Documentação completa + repositório organizado |

---

## Definition of Done do Projeto

Ver `PRD.md` §10. Resumo: ambiente sobe, seed roda, queries documentadas, pipeline funciona, dashboard ativo, docs completas, migração analisada, incidente respondido, repo organizado.

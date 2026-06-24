# PRD — Plataforma de Dados Trio (Desafio Técnico)

> **Documento de Requisitos de Produto** · Engenheiro de Dados Sênior
> **Versão:** 1.0 · **Prazo:** 7 dias corridos · **Classificação:** Confidencial

---

## 1. Visão Geral

Construir uma **réplica funcional, autocontida e demonstrável** da plataforma de dados da Trio Grupo Financeiro — uma instituição de pagamentos de alto volume (Pix, TED, boleto, cartão) — capaz de processar, sincronizar, servir e operar dados transacionais financeiros em escala realista.

O entregável não é um protótipo de slides: é um ambiente `docker-compose up -d` que sobe sem erros, popula bancos com volume relevante (10M+ transações), roda queries otimizadas com `EXPLAIN ANALYZE` documentado, sincroniza dados via pipeline idempotente, expõe dashboards e endpoints, e demonstra maturidade operacional (backup, recovery, resposta a incidentes).

### O que estamos construindo

Uma plataforma de dados de três pilares espelhando a arquitetura real da Trio:

- **TimescaleDB** — banco transacional principal (séries temporais de alta volumetria, reconciliação).
- **ClickHouse** — motor analítico que serve tanto dashboards (Data Champions) quanto aplicações internas via API.
- **PostgreSQL** — legado transacional, com plano de migração para Aurora/RDS.

Conectados por pipelines confiáveis, observados por Grafana, e operados com runbooks e estratégias de continuidade pensadas para AWS.

---

## 2. Contexto de Negócio

A Trio é Instituição de Pagamento autorizada pelo Banco Central, participante direta do Pix, processando milhões de transações diárias em tempo real com tecnologia 100% proprietária. Segmentos: pagamentos corporativos, iGaming, serviços financeiros integrados.

Em infraestrutura de pagamentos de missão crítica, **cada minuto de indisponibilidade tem impacto direto**. A plataforma de dados sustenta:

- **Reconciliação financeira** intraday e fim de dia.
- **Visibilidade de volume em tempo real** para os times comercial, financeiro e marketing.
- **Regras de negócio** alimentadas diretamente pelo motor analítico.
- **Prevenção a fraudes** (detecção de duplicatas, padrões anômalos).

A operação roda sobre **AWS**. O Engenheiro de Dados precisa transitar com fluência entre Timescale Cloud (managed), ClickHouse, PostgreSQL/Aurora e os serviços de suporte (EC2, RDS, S3, VPC, IAM, CloudWatch).

---

## 3. Personas

| Persona | Necessidade | Como a plataforma atende |
|---|---|---|
| **Data Champions** (analistas em comercial/financeiro/marketing) | Dados frescos para dashboards no Grafana/Hex; autonomia para criar queries | ClickHouse com MVs pré-agregadas, dictionaries, queries sub-segundo |
| **Aplicações internas** (painel de operações, regras de negócio) | Volume transacional em tempo real via API | Endpoint FastAPI consultando ClickHouse, retornando JSON |
| **Time financeiro** | Reconciliação intraday confiável | Continuous aggregates no TimescaleDB, divergências detectáveis |
| **Engenheiro de Dados (eu)** | Operar, otimizar, migrar, recuperar sob pressão | Runbooks, backups, observabilidade, ADRs |
| **Liderança (Head de Cloud/Data)** | Decisões justificadas, postura de ownership | Documentação como cidadã de primeira classe, ADRs, análise de trade-offs |

---

## 4. Objetivos e Métricas de Sucesso

Os objetivos mapeiam diretamente aos **critérios de avaliação** do desafio:

| Objetivo | Peso | Métrica de sucesso |
|---|---|---|
| **Profundidade Técnica** | 40% | Tuning real de TimescaleDB/ClickHouse/PostgreSQL; `EXPLAIN ANALYZE` antes/depois em todas as queries; escolhas de engine/índice/particionamento justificadas |
| **Arquitetura e Visão** | 25% | Diagrama completo origem→consumo; ADR com trade-offs; plano de escala 10x; visão cloud-native AWS |
| **Operação e Resiliência** | 20% | Backup/recovery funcional nos 3 bancos; runbook de incidente; 5+ alertas; observabilidade |
| **Comunicação e Liderança** | 15% | Documentação clara; resposta ao incidente SEV-1 estruturada; defesa de decisões na apresentação |

### Métricas técnicas-alvo

- **Seed:** 10M+ transações geradas em **< 15 min** (via `COPY`/batch).
- **Queries D1:** todas com plano de execução documentado e otimização comprovada.
- **Query Grafana (ClickHouse):** sub-segundo mesmo com centenas de milhões de registros.
- **Pipeline:** idempotente (re-execução = zero duplicatas), com lag observável.
- **Recovery:** RTO demonstrável com validação de contagem antes/durante/depois.

---

## 5. Requisitos Funcionais

### RF-1 · TimescaleDB — Modelagem Transacional e Séries Temporais

- **RF-1.1** Schema transacional: `transactions`, `accounts`, `reconciliation_events`.
- **RF-1.2** `transactions` como hypertable com chunk interval e dimensão temporal justificados.
- **RF-1.3** Seed de 10M+ transações em 12 meses, distribuição realista (mais Pix; picos em dias úteis; variação de status; múltiplas instituições).
- **RF-1.4** Continuous aggregates: (a) volume/valor por tipo por hora; (b) P95/P99 de latência de liquidação por instituição por dia.
- **RF-1.5** Políticas: retenção raw 90 dias, CAggs 2 anos, compressão automática de chunks 7+ dias.
- **RF-1.6** Queries Q1–Q4 otimizadas com `EXPLAIN ANALYZE` antes/depois, índices justificados.
- **RF-1.7** Query com `time_bucket_gapfill` + `locf`/`interpolate` para série contínua 48h.
- **RF-1.8** Procedimento de sanitização LGPD de chunks comprimidos com PII.

### RF-2 · PostgreSQL Legado — Avaliação e Migração

- **RF-2.1** Schema legado (usuários, contas, parâmetros de instituições) + seed.
- **RF-2.2** 2+ queries complexas otimizadas com `EXPLAIN ANALYZE`.
- **RF-2.3** Documento de migração: on-prem/EC2 vs Aurora vs RDS; critérios; estratégia zero-downtime; riscos e rollback.

### RF-3 · ClickHouse — Motor de Dados

- **RF-3.1** Schema com engine justificada (MergeTree family), `ORDER BY`, `PARTITION BY`, compressão por coluna.
- **RF-3.2** Materialized views: (a) resumo diário por instituição/tipo; (b) funil de status com tempo médio por estágio.
- **RF-3.3** Dictionary (ex: institution_code → name) com uso demonstrado e justificativa vs JOIN.
- **RF-3.4** Query Grafana: taxa de sucesso Pix por instituição por hora (24h) com delta % vs dia anterior, sub-segundo.
- **RF-3.5** API (FastAPI) servindo ClickHouse diretamente para aplicação (não só dashboard).

### RF-4 · Pipelines de Dados

- **RF-4.1** Pipeline TimescaleDB → ClickHouse com abordagem justificada (CDC vs replicação lógica vs custom).
- **RF-4.2** Pipeline idempotente, com retry/dead-letter/logging, observabilidade (lag/throughput), demonstrável.
- **RF-4.3** Tratamento de mutações (status pending→settled refletido corretamente).
- **RF-4.4** Pipeline secundário PostgreSQL → ClickHouse alimentando dictionaries.
- **RF-4.5** Análise de comportamento do pipeline sob migração PostgreSQL → Aurora.
- **RF-4.6** Diagrama arquitetural completo + ADR de 1–2 páginas.

### RF-5 · Operação, Resiliência e Observabilidade

- **RF-5.1** Estratégia de backup para os 3 bancos (tipo, frequência, retenção, script funcional, destino AWS).
- **RF-5.2** Procedimento de recovery demonstrado (simular perda, restaurar, validar).
- **RF-5.3** Runbook: storage Timescale Cloud em 92%, sanitizar/remover chunks 6+ meses sem downtime.
- **RF-5.4** Dashboards Grafana: TimescaleDB, ClickHouse, Pipeline, PostgreSQL legado.
- **RF-5.5** 5+ alertas críticos (métrica, threshold, severidade, ação, integração CloudWatch/SNS).
- **RF-5.6** Resposta escrita ao incidente SEV-1 (linha de investigação, árvore de hipóteses, resolução, pós-incidente, comunicação).

---

## 6. Requisitos Não-Funcionais

| Categoria | Requisito |
|---|---|
| **Reprodutibilidade** | `docker-compose up -d` sobe todo o ambiente sem erros; versões conforme o ambiente fornecido pelo escopo (§2.2: TimescaleDB 2.x, PostgreSQL 16, ClickHouse `latest`, Grafana). Em produção AWS, pinar imagens com tag/digest fixos |
| **Performance** | Queries analíticas sub-segundo no ClickHouse; queries TimescaleDB otimizadas via particionamento temporal |
| **Idempotência** | Re-execução de seeds e pipelines não gera duplicatas |
| **Observabilidade** | Logs estruturados; métricas de lag/throughput; dashboards funcionais |
| **Resiliência** | Retry com backoff; dead-letter; health checks; restart policies |
| **Segurança** | Sem credenciais hardcoded; `.env.example`; pensar IAM/VPC/security groups na narrativa AWS |
| **Conformidade** | Tratamento LGPD para PII (sanitização de chunks comprimidos) |
| **Documentação** | "Se não está documentado, não existe" — README raiz + REPORTs + ADRs + runbooks |

---

## 7. Arquitetura de Alto Nível

```
┌─────────────────────────────────────────────────────────────────────┐
│                          FONTES (transacional)                       │
│                                                                       │
│   ┌──────────────────┐              ┌──────────────────┐             │
│   │   TimescaleDB    │              │   PostgreSQL     │             │
│   │  (hypertables,   │              │    (legado:      │             │
│   │   CAggs, comp.)  │              │  ref/config)     │             │
│   └────────┬─────────┘              └────────┬─────────┘             │
└────────────┼─────────────────────────────────┼──────────────────────┘
             │ pipeline principal               │ pipeline de referência
             │ (micro-batch / CDC)              │ (sync dictionaries)
             ▼                                  ▼
┌─────────────────────────────────────────────────────────────────────┐
│                       ClickHouse (motor de dados)                    │
│   ReplacingMergeTree · Materialized Views · Dictionaries             │
└──────────┬──────────────────────────────────────────┬───────────────┘
           │                                           │
           ▼                                           ▼
┌────────────────────┐                      ┌────────────────────────┐
│   Grafana / Hex    │                      │   API (FastAPI)        │
│  (Data Champions)  │                      │  (apps internas, RT)   │
└────────────────────┘                      └────────────────────────┘

  Suporte AWS (produção): VPC/subnets · S3 (backups + lifecycle) ·
  CloudWatch + SNS (alertas) · IAM · MSK/Kafka (CDC futuro) · DMS (migração)
```

Detalhamento completo de fluxos, SLAs, pontos de falha e serviços AWS no **Desafio 2 / ADR**.

---

## 8. Stack Tecnológico

| Camada | Tecnologia | Justificativa |
|---|---|---|
| Transacional principal | TimescaleDB 2.x | Hypertables, continuous aggregates, compressão nativa para séries temporais financeiras |
| Legado transacional | PostgreSQL 16 | Espelha o legado; base para análise de migração Aurora/RDS |
| Motor analítico | ClickHouse `latest` (conforme ambiente fornecido, §2.2) | Colunar, sub-segundo em escala, MVs e dictionaries |
| Dashboards | Grafana | Conecta nativamente a ClickHouse/PostgreSQL; padrão dos Data Champions |
| Pipeline | Python 3.12 (psycopg, clickhouse-connect) | Micro-batch idempotente, demonstrável no compose; CDC (Debezium/Kafka) como evolução |
| API | FastAPI + Uvicorn | Endpoint leve servindo ClickHouse; experiência prévia |
| Orquestração local | docker-compose | Ambiente 100% autocontido conforme requisito |
| Geração de dados | Python (Faker + numpy) + `COPY` | Volume de 10M+ em janela aceitável |

---

## 9. Escopo e Não-Escopo

### No escopo
- Ambiente docker-compose completo dos 3 bancos + Grafana + pipeline + API.
- Seed realista de 10M+ transações.
- Todas as queries, otimizações e `EXPLAIN ANALYZE` dos 3 desafios.
- Backup/recovery funcional, dashboards, alertas definidos.
- Documentação completa (PRD, ADR, runbooks, REPORTs, análise de migração, resposta a incidente).

### Fora do escopo (mas endereçado na narrativa AWS)
- Provisionamento real na AWS (descrito em ADR/runbooks, não implementado).
- Kafka/Debezium rodando em produção (justificado como evolução; micro-batch é o entregue).
- Hex (mencionado como consumidor; Grafana é o demonstrado).
- Migração real para Aurora (planejada e documentada, não executada).

---

## 10. Critérios de Aceitação (Definition of Done do Projeto)

Espelham os **critérios mínimos** do desafio e são a barra de entrega:

- [x] `docker-compose up -d` sobe todo o ambiente sem erros.
- [x] Scripts de seed rodam e populam os bancos com volume relevante (10M+).
- [x] Queries do Desafio 1 executam com sucesso e têm `EXPLAIN ANALYZE` documentado.
- [x] Pipeline TimescaleDB → ClickHouse funciona end-to-end de forma demonstrável.
- [x] Pelo menos um dashboard Grafana funcional consultando ClickHouse.
- [x] Documentação cobre decisões técnicas com justificativas.
- [x] Análise de migração PostgreSQL → Aurora presente e fundamentada.
- [x] Runbook de incidente e resposta ao SEV-1 escritos e defensáveis.
- [x] Repositório organizado conforme estrutura sugerida + README raiz.

---

## 11. Riscos e Mitigações

| Risco | Impacto | Mitigação |
|---|---|---|
| Seed ingênuo (INSERT linha a linha) leva horas | Bloqueia todo o resto | `COPY FROM` + geração em batches; validar no Sprint 1 |
| Imagem ClickHouse `latest` (exigida pelo escopo §2.2) muda de comportamento | Quebra ambiente perto da entrega | Registrar a versão/digest efetivamente usada na entrega + smoke test; pinagem com tag fixa fica como recomendação de produção AWS |
| Continuous aggregate sem refresh policy | Dados não materializam silenciosamente | `add_continuous_aggregate_policy` + validação explícita |
| Compressão impede sanitização LGPD direta | Falha no requisito RF-1.8 | Procedimento descomprimir→sanitizar→recomprimir documentado |
| Kafka/Debezium instável no compose local | Pipeline não demonstrável | Micro-batch Python como entrega; CDC como narrativa AWS |
| Perguntas na apresentação fora do entregue | Perda na nota de comunicação | Preparar respostas para migração de engine ClickHouse, novos consumers, escala 10x |
| Subestimar tempo de documentação | Entrega incompleta | Sprint 7 dedicado; documentar incrementalmente em cada sprint |

---

## 12. Roadmap de Sprints

Mapeamento ao prazo de 7 dias. Cada sprint é um documento dedicado em `sprints/`, quebrado em **stories isoladas** para o workflow per-story com `/compact` entre elas.

| Sprint | Foco | Dia(s) | Cobre |
|---|---|---|---|
| **00** | Foundation & Infra (docker-compose, init, env) | 1 | Critérios mínimos de ambiente |
| **01** | TimescaleDB — modelagem, hypertable, seed 10M | 1–2 | RF-1.1 a RF-1.3 |
| **02** | TimescaleDB — CAggs, políticas, queries Q1–Q4, LGPD | 2–3 | RF-1.4 a RF-1.8 |
| **03** | PostgreSQL legado — schema, queries, migração | 3 | RF-2.1 a RF-2.3 |
| **04** | ClickHouse — schema, MVs, dictionary, query Grafana, API | 3–4 | RF-3.1 a RF-3.5 |
| **05** | Pipelines & Arquitetura — sync, mutações, diagrama, ADR | 4–5 | RF-4.1 a RF-4.6 |
| **06** | Ops & Observabilidade — backup, recovery, dashboards, alertas | 5–6 | RF-5.1 a RF-5.5 |
| **07** | Incidente & Entrega — SEV-1, README, prep apresentação | 7 | RF-5.6 + empacotamento |

---

## 13. Referências

- **Documento-fonte:** `Desafio Técnico — Engenheiro de Dados Sênior — Trio`
- **Skill de trabalho:** `token-economy` (Sonnet padrão, `/compact` a 60%, referências cirúrgicas, sprints granulares)
- **Estrutura de entrega:** ver Seção 6 do documento-fonte

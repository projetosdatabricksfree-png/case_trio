# Arquitetura de Dados — Diagramas (Desafio 2 · Story 5.5)

Dois diagramas: **(1) as-built** — exatamente o que sobe no `docker-compose` e é
defensável ao vivo — e **(2) target AWS** — a evolução cloud-native (CDC, sharding,
DR) discutida no [ADR](../ADR.md). Fluxos da origem ao consumo, com **SLAs por hop**
e **pontos de falha + mitigação** anotados.

---

## 1) As-built (docker-compose) — o que roda hoje

```mermaid
flowchart LR
    subgraph SRC["Origens (OLTP)"]
        TS[("TimescaleDB<br/>trio_transactions<br/>transactions (hypertable)")]
        PG[("PostgreSQL legado<br/>trio_legado<br/>institution_configs")]
    end

    subgraph PIPE["Pipelines (micro-batch Python)"]
        P1["pipeline · ts_to_ch<br/>loop contínuo / --once<br/>janela created_at + sweep settled_at"]
        P2["pipeline-refs · pg_refs<br/>full-refresh one-shot"]
    end

    subgraph CH["ClickHouse — trio_analytics (OLAP)"]
        T[["transactions<br/>ReplacingMergeTree(version)"]]
        MV["MVs: tx_daily_summary<br/>tx_status_funnel<br/>AggregatingMergeTree"]
        DICT{{"dict_institutions<br/>SOURCE = PostgreSQL direto"}}
        REF["ref_institutions<br/>cópia local consultável"]
        CTL["controle: pipeline_watermark<br/>pipeline_runs · pipeline_dlq"]
    end

    subgraph CONS["Consumo"]
        API["API FastAPI<br/>:8000"]
        GRAF["Grafana<br/>:3000"]
    end

    TS -- "INSERT pass: janela de tempo created_at (poda de chunk)<br/>MUTATE pass: keyset settled_at<br/>SLA freshness ≤ poll (~10s)" --> P1
    P1 -- "INSERT micro-batch<br/>id/external_id carregados → dedup" --> T
    P1 -. "commit watermark<br/>+ métricas por run" .-> CTL
    P1 -. "poison → DLQ" .-> CTL
    T -- "materializa no INSERT" --> MV

    PG -- "full-refresh (~30 linhas)<br/>SLA ≤ 1h (cron)" --> P2
    P2 -- "TRUNCATE + INSERT" --> REF
    P2 -. "SYSTEM RELOAD DICTIONARY" .-> DICT
    PG -- "LIFETIME 300–600s / reload" --> DICT

    T -- "raw + FINAL/argMax<br/>flagship sub-segundo" --> API
    DICT -- "dictGet O(1)" --> API
    T --> GRAF
    MV --> GRAF
    CTL -- "dashboard de pipeline (Sprint 06)" --> GRAF

    classDef src fill:#e3f2fd,stroke:#1565c0;
    classDef pipe fill:#fff3e0,stroke:#e65100;
    classDef ch fill:#f3e5f5,stroke:#6a1b9a;
    classDef cons fill:#e8f5e9,stroke:#2e7d32;
    class TS,PG src;
    class P1,P2 pipe;
    class T,MV,DICT,REF,CTL ch;
    class API,GRAF cons;
```

**Pontos de falha & mitigação (as-built):**

| Hop | Falha | Mitigação implementada |
|---|---|---|
| TS → pipeline | banco indisponível / query lenta | retry + backoff exponencial; leitura por **janela de tempo** (poda de chunk na hypertable comprimida) + índice `(settled_at, id)` para o sweep de mutações |
| pipeline → CH | INSERT falha / CH down | retry + backoff; watermark **não** avança sem confirmar o batch → reprocessa |
| pipeline (dado) | registro poison (fora do domínio) | validação por linha → **DLQ** (`pipeline_dlq`), não trava o batch |
| re-sincronização | mutação duplicaria a linha | `id` carregado da origem + `ReplacingMergeTree(version)` → versão maior vence |
| leitura mutável | versão antiga visível antes do merge | `FINAL`/`argMax(version)` na query crítica; `OPTIMIZE … FINAL` agendável |
| dict desatualizado | mudança em institution_configs | `LIFETIME` + `SYSTEM RELOAD DICTIONARY` disparado pelo pipeline de referência |

**Decisão central:** **micro-batch idempotente** (watermark + ReplacingMergeTree), não
CDC — 100% demonstrável no compose. Justificativa e plano de escala no [ADR](../ADR.md).

---

## 2) Target AWS — evolução cloud-native (10x+)

```mermaid
flowchart LR
    subgraph VPC["AWS VPC (subnets privadas)"]
        subgraph SRCA["Origens gerenciadas"]
            TSC[("Timescale Cloud<br/>/ RDS PostgreSQL")]
            AUR[("Aurora PostgreSQL<br/>legado · Global DB (DR)")]
        end

        subgraph INGEST["Ingestão CDC"]
            DBZ["Debezium<br/>connectors"]
            MSK[["Amazon MSK<br/>Kafka · tópico por instituição"]]
            DMS["AWS DMS<br/>migração PG → Aurora"]
        end

        subgraph CHC["ClickHouse (cluster)"]
            SH["ReplicatedMergeTree<br/>sharding + réplicas"]
            MVA["MVs / dictionaries"]
        end

        subgraph CONSA["Consumo"]
            APIA["API (ECS/EKS)<br/>Auto Scaling"]
            GRAFA["Grafana / Hex"]
        end
    end

    OBS["CloudWatch + SNS<br/>métricas, logs, alertas"]
    S3[("S3<br/>backups + lifecycle/Glacier")]
    IAM["IAM<br/>roles, IRSA, least-privilege"]

    AUR -. "DMS (one-time + CDC)" .-> DMS
    DMS --> AUR
    TSC -- "CDC (logical decoding)" --> DBZ
    AUR -- "CDC referência" --> DBZ
    DBZ --> MSK
    MSK -- "consumer idempotente<br/>SLA latência segundos" --> SH
    SH --> MVA
    SH --> APIA
    MVA --> GRAFA
    SH -. "backup / part export" .-> S3
    CHC -. "métricas/lag" .-> OBS
    INGEST -. "lag de consumer" .-> OBS
    OBS -. "alarmes" .-> SNS_NOTE["on-call / runbook"]
    IAM -. "auth de todos os hops" .-> VPC

    classDef mng fill:#e3f2fd,stroke:#1565c0;
    classDef ing fill:#fff3e0,stroke:#e65100;
    classDef ch fill:#f3e5f5,stroke:#6a1b9a;
    classDef ops fill:#fce4ec,stroke:#ad1457;
    class TSC,AUR mng;
    class DBZ,MSK,DMS ing;
    class SH,MVA ch;
    class OBS,S3,IAM,SNS_NOTE ops;
```

**O que muda da as-built para a target (e o que NÃO muda):**

- **Pipeline principal:** micro-batch Python → **CDC (Debezium + MSK)** para latência de
  segundos e throughput horizontal (tópico por instituição). O **contrato de dados** e a
  semântica de idempotência (dedup por `ReplacingMergeTree`) permanecem.
- **ClickHouse:** `MergeTree` single-node → **`ReplicatedMergeTree` + sharding** (escala de
  escrita/leitura, alta disponibilidade).
- **Legado:** PostgreSQL → **Aurora** via **DMS**; o pipeline de referência **só troca a
  connection string** (Aurora é wire-compatible) — lógica intacta.
- **Operação:** logs JSON + tabelas de controle → **CloudWatch + SNS** (alertas), **S3**
  (backups com lifecycle), **IAM** (least-privilege), **Aurora Global Database** (DR).

> SLAs-alvo: freshness do pipeline **segundos** (CDC) vs. **≤ ~poll+batch** (micro-batch
> atual); query analítica **sub-segundo** (mantida pelo design de `ORDER BY`/partição).

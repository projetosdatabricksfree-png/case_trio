# ADR-0002 — Pipeline TimescaleDB → ClickHouse: micro-batch vs CDC

- **Status:** Aceito
- **Data:** 2026-06-23
- **Contexto:** Sprint 05 (Pipelines & Arquitetura) · Desafio 2 (RF-4.1 a RF-4.6)
- **Decisores:** Engenharia de Dados
- **Relacionado:** [diagramas](diagrams/architecture.md) · [ADR-0001 (imagens)](../docs/adr/ADR-0001-image-versioning.md)

## Contexto

A plataforma tem um **OLTP** (TimescaleDB, `transactions`) e um **OLAP** (ClickHouse,
`trio_analytics`) que serve Data Champions (dashboards) e aplicações (API). É preciso um
**pipeline que leve dados do OLTP ao OLAP de forma demonstrável, idempotente e observável**,
refletindo **mutações de status** (`pending → settled`). Há ainda dados de **referência** no
PostgreSQL legado (`institution_configs`) que alimentam o dictionary do ClickHouse.

Restrições: tudo precisa subir no `docker-compose` e ser **defensável ao vivo** em 7 dias; sem
infraestrutura pesada; sem segredos no repositório; sem quebrar as sprints já entregues.

## Decisão

1. **Pipeline principal = micro-batch Python idempotente** (`sync_ts_to_ch`), serviço de longa
   duração no compose (loop com poll) e com modo `--once` determinístico.
   - **Leitura amigável à hypertable COMPRIMIDA** (a origem usa a compressão da Sprint 02; uma
     leitura ordenada global por expressão custaria um `Sort` de milhões por batch). Duas passadas:
     **(a) INSERT** por **janelas de tempo** sobre `created_at` (coluna de partição/orderby da
     compressão) → poda de chunk, sem Sort; cobre backfill e linhas novas. **(b) MUTATE** por
     **keyset `(settled_at, id)`** → capta `pending → settled` (a mutação preenche `settled_at`),
     com o watermark iniciado em `max(settled_at)` para pegar só mutações futuras.
   - **Sem coluna `updated_at` nem trigger na origem** (a única mutação do domínio é
     status/settled_at) — `version` no destino = `COALESCE(settled_at, created_at)`.
   - **Idempotência = watermark + `ReplacingMergeTree(version)`.** O watermark evita re-ler o
     inalterado; o Replacing colapsa o reinserido. O `id`/`external_id` da **origem** são
     carregados explicitamente — sem isso a re-sincronização de uma linha mutada ganharia UUID
     novo e viraria duplicata.
2. **Pipeline secundário = full-refresh** (`sync_pg_refs`): copia `institution_configs` →
   `ref_institutions` (ClickHouse) e dispara `SYSTEM RELOAD DICTIONARY`. O dictionary segue
   lendo o PostgreSQL direto (Sprint 04 intacta); o reload força o refresh sem esperar o `LIFETIME`.
3. **Observabilidade** por logs JSON + tabelas de controle (`pipeline_runs`, `pipeline_watermark`,
   `pipeline_dlq`) que o dashboard da Sprint 06 consome.

## Alternativas consideradas

| Alternativa | Por que NÃO (agora) |
|---|---|
| **CDC com Debezium + Kafka/MSK** | Fiel a produção, mas pesado e instável em docker local; risco real de **não ser demonstrável** no prazo. É a **evolução-alvo** (ver abaixo). |
| **Replicação lógica nativa** (TimescaleDB é PostgreSQL) | Elegante, mas complexa de orquestrar e com nuances em **chunks comprimidos**; menos transparente para inspeção ao vivo. |
| **ETL batch noturno** | Simples, mas **freshness inaceitável**: Data Champions e a API precisam de dados de minutos, não do dia anterior. |
| **Coluna `updated_at` + trigger na origem** | Mais geral (capta qualquer UPDATE), porém exigiria **alterar o schema e re-semear** a Sprint 01. Como o domínio só muta status/settled_at, o **watermark derivado** entrega o mesmo resultado sem churn. Fica como recomendação quando surgirem mutações além de status. |

## Consequências

**Positivas**
- Pipeline **100% demonstrável** no compose; idempotência provável rodando 2× (contagem com
  `FINAL` não muda) e mutação refletida end-to-end.
- **Sem segredo no repositório**; credenciais via `.env`/env por serviço.
- **Concorrência segura**: serviço contínuo + `--once` simultâneos no pior caso reprocessam
  (Replacing deduplica; watermark é monotônico) — não corrompe.
- Caminho de evolução claro (mesmo contrato de dados na migração para CDC).

**Negativas / custos**
- Latência de **minutos/poll**, não de segundos (resolvido na evolução CDC).
- **Watermark derivado** não capta updates fora de status/settled_at (aceitável no domínio atual).
- **MV conta o bloco inserido antes do dedup** → re-sincronizar uma mutação **conta em dobro** nas
  MVs (ver trade-offs).

## Trade-offs documentados

- **Consistência de leitura (mutação):** entre o `UPDATE` na origem e o merge no ClickHouse,
  uma leitura **sem `FINAL`** pode ver a versão antiga. Mitigação: `FINAL`/`argMax(…, version)` na
  query crítica (a flagship e a API já usam o caminho correto) e/ou `OPTIMIZE … FINAL` agendado.
- **Double-count das MVs (gancho da Sprint 04, agora real):** como a MV agrega o bloco inserido
  **antes** do dedup, uma transação sincronizada duas vezes (pending→settled) é contada duas vezes
  nas MVs. As MVs servem **tendência**; **contabilidade exata** usa a tabela raw com `FINAL`/`argMax`.
  Evolução: MV alimentada só por estado terminal, ou reconciliação periódica.
- **Watermark derivado vs. `updated_at` real:** trocamos generalidade por zero churn; registrado
  como recomendação de produção.
- **Sweep de mutação em chunk comprimido:** o keyset por `settled_at` em chunks comprimidos vira
  `ColumnarScan` (settled_at não é orderby da compressão). O custo é contido — o watermark inicia em
  `max(settled_at)`, então o sweep só materializa mutações novas. Produção (CDC) lê o WAL e dispensa o sweep.

---

## Perguntas-âncora (defesa na apresentação)

### 1. Por que não um ETL tradicional?
Batch noturno entrega freshness de **horas/dia** — incompatível com dashboards operacionais e com a
API que serve regra de negócio em tempo quase real. O micro-batch entrega **minutos** já hoje e
evolui para **segundos** com CDC, sem reescrever o contrato de dados.

### 2. Como escalar se o volume crescer 10x?
- **Pipeline:** migrar micro-batch → **CDC (Debezium + Amazon MSK)**; **particionar por
  instituição** (tópico/partição) para throughput e latência de segundos; consumers idempotentes
  mantêm a mesma semântica de dedup.
- **ClickHouse:** **`ReplicatedMergeTree` + sharding** (distribuir partições, réplicas para HA);
  revisar `index_granularity` e políticas de merge sob volume real.
- **TimescaleDB:** ajustar **chunk interval**, mais compressão, **read replicas** para isolar a
  carga de leitura do pipeline do OLTP.

### 3. Onde entra o legado PostgreSQL/Aurora nessa evolução?
A referência é **desacoplada por connection string/env**. O destino gerenciado segue a recomendação da
[`migration-analysis.md`](../desafio-1/migration-analysis.md): **RDS PostgreSQL Multi-AZ** para o legado
de **referência/baixo volume** de hoje, com **Aurora** reservado aos gatilhos de escala/DR (muitas
réplicas de leitura, Global Database cross-region). Em **qualquer** dos dois, migrar muda **apenas o
endpoint** (wire-compatible, via **AWS DMS** ou replicação lógica) — o pipeline de referência **não muda
de lógica**. Esse desacoplamento é um princípio de design, não um acidente.

### 4. Quais serviços AWS para resiliência e escala?
- **Amazon MSK** (CDC/streaming), **AWS DMS** (migração + CDC inicial).
- **S3** (backups com lifecycle/Glacier), **CloudWatch + SNS** (métricas, logs, alarmes → on-call).
- **IAM** (least-privilege, IRSA), **Aurora Global Database** (DR), **Auto Scaling** (consumers/API).
- **Secrets Manager/SSM** para credenciais (substitui o `.env` de desenvolvimento).

> Recomendações de produção (registrar no runbook da Sprint 06): pinar imagens por digest;
> credenciais em cofre; DLQ com reprocessamento automatizado; `OPTIMIZE`/merge agendado; alertas de
> **lag** e de **crescimento da DLQ**.

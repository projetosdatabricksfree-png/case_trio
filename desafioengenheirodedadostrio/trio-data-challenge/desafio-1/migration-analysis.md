# Análise de Migração — Legado PostgreSQL → Aurora/RDS

> Sprint 03 · Story 3.4 · Desafio 1 / Parte B (Arquitetura).
> Pergunta-guia: *"Se precisasse migrar o PostgreSQL legado para Aurora amanhã, qual seria seu plano de 72h?"*

## 1. Estado atual

O legado (`trio_legado`, PostgreSQL 16) é um banco de **referência/configuração**, não transacional de
alta escala: `institution_configs`, `institution_partners`, `users`, `accounts`, `account_limits`.
Perfil de carga **leitura-dominante** e volume **baixo** (dezenas de milhares de linhas), consumido por
processos de configuração e — na Sprint 04 — como fonte do dictionary `institution_code → name` do
ClickHouse. Pontos relevantes para a migração:

- **Chaves `bigint GENERATED ALWAYS AS IDENTITY`** (sequências internas) em `users`/`accounts`/
  `institution_partners` → exigem **reconciliação da sequência** no cutover (ver §4).
- Extensão `pg_stat_statements` (observabilidade), tipos `jsonb`, FKs e CHECKs.
- Janela de manutenção tolerável, mas a meta é **downtime mínimo** para não travar configurações.

## 2. Opções comparadas

| Opção | O que é | Prós | Contras |
|---|---|---|---|
| **EC2 auto-gerenciado** | Postgres em VM própria | Controle total; custo de licença zero | Patching, backup, HA e failover por nossa conta; **maior overhead operacional** |
| **RDS for PostgreSQL (Multi-AZ)** | Managed, réplica síncrona em outra AZ | HA gerenciado (failover ~60–120s), backup/PITR, patching automático; **menor custo** | Réplicas de leitura assíncronas custam instâncias cheias; escala de leitura limitada |
| **Aurora PostgreSQL** | Storage distribuído (6 cópias/3 AZ), compute desacoplado | Failover ~30s; até 15 réplicas baratas compartilhando storage; Global Database (DR cross-region); autoscaling de storage | **Custo maior**; compatível mas não idêntico ao Postgres core; lock-in mais forte |

## 3. Matriz de critérios

| Critério | EC2 | RDS Multi-AZ | Aurora |
|---|:---:|:---:|:---:|
| Custo | ★★★ | ★★★ | ★★ |
| Performance | ★★ | ★★★ | ★★★ |
| Alta disponibilidade | ★ | ★★★ | ★★★ |
| Overhead operacional | ★ | ★★★ | ★★★ |
| Escala de leitura | ★ | ★★ | ★★★ |
| Lock-in | ★★★ | ★★★ | ★★ |

### Recomendação

Para um legado de **referência/baixo volume e leitura dominante**, **RDS for PostgreSQL Multi-AZ** é a
escolha de melhor relação custo/HA: entrega failover gerenciado, backup/PITR e patching sem o sobrepreço
do storage distribuído do Aurora. **Migrar para Aurora não se justifica hoje** — é resolver um problema
de escala que este banco não tem. Os **gatilhos** que mudariam a recomendação para Aurora: (a)
necessidade de **múltiplas réplicas de leitura** baratas (ex.: muitos consumidores do dictionary), (b)
**DR cross-region** via Global Database, ou (c) crescimento que torne o storage autoscaling/IO do Aurora
vantajoso. Decisão registrável em ADR.

## 4. Estratégia de migração com downtime mínimo

**Caminho preferencial — replicação lógica nativa** (Postgres → RDS): origem como `publication`, destino
como `subscription`. Copia o snapshot inicial e mantém **CDC contínuo**, permitindo cutover de segundos.
Para Aurora, o equivalente gerenciado é o **AWS DMS** (full load + CDC).

**Alternativa — AWS DMS** quando a replicação lógica nativa não for viável (versões/permissões). Ressalvas
a tratar explicitamente: **DMS não migra sequências** (os valores de IDENTITY precisam de
`setval`/`ALTER … RESTART` no destino após o load — crítico aqui, pois as PKs são `bigint IDENTITY`),
não recria todas as constraints/índices secundários por padrão, e tem atrito com alguns tipos.

**Cutover controlado — RDS Blue/Green Deployments**: cria um ambiente verde replicado, valida em paralelo
e faz o switchover gerenciado (segundos), com a origem (blue) preservada para rollback.

### Runbook de 72h

- **0–24h — Preparação:** provisionar o destino (RDS Multi-AZ); conferir versão/extensões
  (`pg_stat_statements`); criar `publication` na origem e `subscription` no destino (full load +
  streaming); estabelecer baseline de queries com `pg_stat_statements`/`auto_explain`.
- **24–60h — Replicação & paridade:** acompanhar o lag de replicação até ~0; **validar paridade**
  (contagens por tabela, checksums de amostras, FKs); **reconciliar sequências** (`setval` de cada
  IDENTITY ao `max(id)+1`); recriar índices secundários e rodar `ANALYZE` no destino.
- **60–72h — Cutover:** congelar escritas na origem (janela curta) → confirmar lag zero → **swap do
  connection string/DNS** para o destino → janela de **reconciliação** e smoke tests → manter a origem em
  **read-only** como rede de segurança.

## 5. Riscos e plano de rollback

| Risco | Mitigação |
|---|---|
| Divergência de dados pós-load | Validação de paridade (contagens/checksums) antes do swap |
| **Sequências/IDENTITY dessincronizadas** (colisão de PK) | `setval` ao `max(id)+1` no destino antes de liberar escrita |
| Diferença de versão/extensões | Conferência prévia; pinar versão do engine no destino |
| Performance pós-cutover | Recriar índices + `ANALYZE`; comparar com baseline de `pg_stat_statements` |
| Falha de replicação | Monitorar lag; abortar o cutover se o lag não convergir |

**Rollback:** manter a origem **ativa em read-only** até a validação completa; em caso de problema,
**reverter o connection string/DNS** para a origem. Se já houve escrita no destino, usar **replicação
reversa** (destino → origem) para reconciliar antes de voltar. O Blue/Green mantém o ambiente azul
intacto, tornando o rollback uma troca de ponteiro.

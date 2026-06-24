# Resposta a Incidente — SEV-1: volume zero no ClickHouse

> **Desafio 3 · Parte C (RF-5.6) · Sprint 07.** Resposta escrita ao incidente, com árvore de
> hipóteses ordenada, linha de investigação, resolução, ações pós-incidente e comunicação. O
> incidente é o gatilho exato do **alerta #2 (volume = 0)** do catálogo [`alerts.md`](alerts.md) e
> é **reproduzível ao vivo** (ver §7: `make incident-demo`).

## 1. Cenário

**06h47 BRT.** Os dashboards de Pix no Grafana (que leem o **ClickHouse**) mostram **volume ZERO nas
últimas ~2h**. Aplicações que consultam o ClickHouse retornam dados desatualizados. O **TimescaleDB
processa transações normalmente** (a operação não parou — os clientes seguem transacionando).

**Dois eventos na noite anterior** (precisam ser considerados juntos):
1. **Manutenção programada no TimescaleDB** — compressão de chunks.
2. **Atualização de security group (SG)** na VPC.

**Impacto:** camada **analítica** stale, não a transacional. Quem depende do ClickHouse perde visão em
tempo real: comercial (volume RT), financeiro (reconciliação intraday), operações (painéis de
monitoração). Pagamentos em si **não** estão parados.

## 2. Linha de investigação (o que verificar, em que ordem)

Princípio: **confirmar o sintoma → isolar a camada → achar a causa**, do mais barato/rápido para o mais
caro. Cada passo decide o próximo.

**Passo 1 — Confirmar o sintoma nas duas pontas (origem vs. destino).**
```sql
-- TimescaleDB (origem) — tem dado recente?
SELECT max(created_at) FROM transactions;                 -- esperado: ~agora  -> origem OK
-- ClickHouse (destino) — tem dado recente?
SELECT max(created_at) FROM transactions;                 -- esperado: ~2h atrás -> destino PAROU
```
Se a origem está fresca e o destino parou há ~2h, o problema **não é geração de transações**: é a
**propagação** origem → destino.

**Passo 2 — Isolar a camada: pipeline (não chega dado) ou ClickHouse (chega mas não aparece)?**
Olhar o **dashboard de pipeline** (Sprint 06, `grafana/.../pipeline.json`) e a tabela de controle:
```sql
-- ClickHouse: última execução e lag do pipeline
SELECT max(finished_at) AS ultima_run,
       argMax(status, finished_at) AS ultimo_status,
       argMax(lag_seconds, finished_at) AS ultimo_lag
FROM pipeline_runs WHERE pipeline = 'ts_to_ch';
```
- Última run **~2h atrás e não avança** → o pipeline **parou de rodar** (não drena). Vai para o Passo 3.
- Runs recentes com `status='error'` → o pipeline roda mas **falha** ao inserir. Vai para o Passo 5.
- Runs recentes **ok** e mesmo assim CH stale → o problema é **dentro do ClickHouse** (merges/leitura).

**Passo 3 — Saúde e logs do pipeline.**
```bash
docker compose ps pipeline                  # rodando? reiniciando? saiu?
docker compose logs --tail=200 pipeline     # exceptions, timeouts, "connection refused"
```
Procurar o **último log antes do silêncio** e seu timestamp — costuma cravar a causa e a hora.

**Passo 4 — Conectividade das duas pontas (a mudança de SG pode ter cortado uma).**
```bash
# pipeline -> TimescaleDB (5432) e pipeline -> ClickHouse (8123/9000)
docker compose exec pipeline sh -lc 'nc -zv timescaledb 5432; nc -zv clickhouse 8123; nc -zv clickhouse 9000'
```
Em produção (AWS), o equivalente é testar a partir do **host/subnet do pipeline** e cruzar com as
regras do SG (Passo 6).

**Passo 5 — Logs do ClickHouse (se o pipeline roda mas o dado não entra).**
```sql
SELECT event_time, query_kind, exception
FROM system.query_log
WHERE type = 'ExceptionWhileProcessing' AND event_time > now() - INTERVAL 3 HOUR
ORDER BY event_time DESC LIMIT 20;
SELECT count() FROM system.merges;          -- merges travados/crescendo?
```
E a DLQ do próprio pipeline: `SELECT count() FROM pipeline_dlq` — enchendo = inserts rejeitados.

**Passo 6 — Correlação temporal com as duas mudanças.**
Cruzar a **hora do último dado bom** (Passo 1) com a **timeline AWS**: CloudTrail (quem mudou o quê:
`ModifySecurityGroupRules`, janela de manutenção) e CloudWatch (queda das métricas de ingestão). O SG e
a manutenção foram na **mesma noite** — a hora exata do corte é o que separa as hipóteses.

## 3. Árvore de hipóteses (ordenada por probabilidade)

Considerando os **dois** eventos. O sintoma-chave que ordena tudo: **TS saudável + CH parado +
pipeline sem rodar há ~2h** aponta para a propagação, não para os bancos.

| # | Hipótese | Por que (e contra) | Como confirmar |
|---|---|---|---|
| **1** | **SG bloqueou o pipeline** (porta 5432 do TS, ou 8123/9000 do CH) | **Mais provável.** Casa com "TS ok, pipeline parou" e com a hora da mudança de SG. Uma regra removida/estreitada derruba a conexão do pipeline silenciosamente. | Passo 4 (conectividade) + `aws ec2 describe-security-groups` + CloudTrail |
| **2** | **Pipeline morreu na janela de manutenção** sem restart | A compressão derrubou a conexão; o processo caiu e não tinha restart policy. Watermark parado. Plausível e independe do SG. | `docker compose ps pipeline` (Exited), logs com erro no horário da manutenção |
| **3** | **Compressão de chunks** interferiu na leitura incremental | A manutenção mexeu na origem. **Menos provável**: o pipeline lê por janela de `created_at`/keyset de `settled_at` (amigável a chunk comprimido) — a compressão não deveria quebrar a leitura. | Reproduzir a leitura incremental manualmente contra um chunk recém-comprimido |
| **4** | **SG isolou o ClickHouse** dos inserts (não o pipeline da origem) | O pipeline lê o TS mas falha ao **escrever** no CH; inserts estouram timeout, DLQ enche. | `pipeline_runs.status='error'`, `pipeline_dlq` crescendo, logs "connect timeout" ao CH |
| **5** | **Credenciais/IAM/SSL** alterados na manutenção | Rotação de senha/cert ou mudança de `sslmode` quebrando a autenticação do pipeline numa das pontas. | Logs "authentication failed"/"SSL"; testar credenciais manualmente |
| **6** | **ClickHouse degradado** (merges/disco travados) ou **relógio/timezone** criando janela vazia aparente | Cauda. Inserts falham por disco cheio; ou skew de TZ faz a query "últimas 2h" cair fora. TS e pipeline estariam ok. | `system.merges`, `system.parts`, `df`; conferir TZ do host vs. query do dashboard |

**Leitura ordenada:** as hipóteses 1, 2 e 4 explicam diretamente o sintoma e coincidem com os dois
eventos da noite; a **1 é a primeira a verificar** porque a mudança de SG é a alteração de
infraestrutura mais recente e o sintoma ("pipeline não roda, TS ok") é exatamente o que um bloqueio de
rede produz. A 3 é a "tentadora" (a manutenção foi no TS) mas o desenho do pipeline a torna improvável —
vale registrar para não enviesar a investigação.

## 4. Resolução da hipótese mais provável (SG bloqueando o pipeline)

**Diagnóstico (confirmar):**
```bash
# Quem mudou e quando (cravar na timeline do incidente)
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=EventName,AttributeValue=ModifySecurityGroupRules \
  --start-time "$(date -u -d '12 hours ago' +%FT%TZ)"

# Regras atuais do SG do banco/destino (a porta do pipeline ainda é permitida?)
aws ec2 describe-security-groups --group-ids sg-XXXX \
  --query 'SecurityGroups[].IpPermissions[?FromPort==`5432` || FromPort==`9000`]'
```
Esperado: a regra de **inbound** que permitia o **SG/subnet do pipeline** na porta do TimescaleDB
(5432) e/ou do ClickHouse (9000/8123) foi **removida ou estreitada** na janela da noite.

**Correção (restaurar o acesso):**
```bash
# Re-permitir o SG do pipeline na porta afetada (exemplo: ClickHouse nativo 9000)
aws ec2 authorize-security-group-ingress --group-id sg-XXXX \
  --protocol tcp --port 9000 --source-group sg-PIPELINE
```

**Validação (o lag drena e o volume volta):**
```bash
# 1) Conectividade restabelecida
docker compose exec pipeline sh -lc 'nc -zv clickhouse 9000'
# 2) Pipeline volta a rodar (restart do serviço / auto-recover)
docker compose start pipeline
# 3) max(created_at) do CH converge com o do TS; volume nos dashboards Pix volta
#    (TS) SELECT max(created_at) FROM transactions;   ==   (CH) SELECT max(created_at) FROM transactions;
```
Critério de "resolvido": `CH max(created_at) == TS max(created_at)` (atraso drenado) e os painéis de
volume voltando a registrar. **É exatamente o que `make incident-demo` valida** (§7).

## 5. Ações pós-incidente (preventivo, não só detectivo)

O incidente durou ~2h **antes de ser percebido** — a maior falha foi de **detecção**.

- **Detecção rápida (já previsto na Sprint 06):**
  - **Alerta de lag / última execução do pipeline** com threshold agressivo (`alerts.md` #1) — teria
    paginado em **minutos**, não 2h. PoC já provisionada no Grafana (`alerting/alerts.yml`).
  - **Alerta de volume = 0 em horário comercial / SEV-1** (`alerts.md` #2, `treatMissingData=breaching`)
    — pega o sintoma de negócio diretamente.
- **Resiliência da rede:** mudanças de SG via **IaC** (Terraform) com **revisão obrigatória** e
  **canary/health-check de conectividade pós-change** (uma Lambda que testa as portas a partir do
  pipeline e faz rollback automático se falhar).
- **Resiliência do pipeline:** `restart: unless-stopped` + **healthcheck** (já há heartbeat) +
  auto-recover; assim a hipótese 2 (processo morto sem restart) não vira incidente de 2h.
- **Runbook "ClickHouse com dados stale"** linkado ao alerta — os Passos 1–6 desta investigação viram
  um checklist acionável pelo on-call.
- **Janela de manutenção com checklist de saída:** validar **pipelines downstream** antes de encerrar a
  manutenção (não declarar "concluída" enquanto o consumidor analítico não confirmar ingestão).
- **Post-mortem blameless** agendado em ≤ 48h, com action items rastreados.

## 6. Comunicação para os times afetados

**Durante (abertura, canal de incidentes `#sev1`):**
> 🔴 **SEV-1 ABERTO — 06h47** · Dashboards Pix (ClickHouse) sem volume há ~2h. **Pagamentos NÃO
> afetados** (TimescaleDB normal); impacto é em **analytics em tempo real**. Times afetados: Comercial
> (volume RT), Financeiro (reconciliação intraday), Operações (painéis stale). Hipótese principal:
> mudança de security group da noite cortou o pipeline. **Owner:** @on-call-dados. **ETA diagnóstico:**
> 30 min. Próximo update: 07h15.

**Updates periódicos (a cada 15–30 min):**
> ⏳ **07h15** · Confirmado: pipeline sem rodar desde 04h47; regra de SG na porta do ClickHouse foi
> alterada às 04h41 (CloudTrail). Restaurando o acesso. ETA de normalização: 20 min.

**Encerramento:**
> ✅ **SEV-1 RESOLVIDO — 07h35** · Regra de SG restaurada; pipeline drenou o atraso; volume voltou em
> todos os dashboards. **Causa raiz:** change de SG removeu o inbound do pipeline → ClickHouse.
> **Duração:** 48 min de resposta / ~2h de defasagem. **Nenhuma transação perdida** (TS é a fonte da
> verdade; o pipeline é idempotente e fez backfill). Post-mortem blameless: amanhã 14h. Action items:
> alerta de lag agressivo, SG via IaC com canary, restart policy do pipeline.

## 7. Demonstração ao vivo (`make incident-demo`)

O incidente é **reproduzível e auto-validável** no ambiente do compose
([`scripts/incident-demo.sh`](../scripts/incident-demo.sh)):

```bash
make incident-demo
```
O script: **(1)** para o pipeline — *stand-in fiel do SG que cortou a rede*; **(2)** injeta novas
transações no TimescaleDB (clientes seguem transacionando) → o ClickHouse fica **stale**; **(3)** imprime
a investigação (TS `max(created_at)` recente × CH defasado × última run parada — isolando a camada);
**(4)** "restaura o acesso" reativando o pipeline, que **drena** o atraso; **(5)** valida a convergência
`CH max(created_at) == TS max(created_at)` (sai 0/1). As transações sintéticas são marcadas em
`metadata` e limpas ao final — não tocam o dado real do seed. Roda também no **CI** (passo "Sprint 07").

> **Por que `stop pipeline` representa o SG:** no compose não há VPC/Security Groups; o efeito de um SG
> que bloqueia a porta do pipeline é, do ponto de vista do dado, **idêntico** a parar o processo do
> pipeline — a origem continua recebendo, o destino para de ser alimentado. A resolução real na AWS
> (`authorize-security-group-ingress`) está documentada em §4.

# Runbook — Storage do Timescale Cloud em 92%

> Sprint 06 · Story 6.3 · Desafio 3 / Parte A.
> **Cenário:** o storage da hypertable `transactions` chegou a **92%**. Chunks
> comprimidos de **6+ meses** precisam ser **sanitizados e removidos** para liberar
> espaço — **sem downtime** e **sem perder os dados agregados** dos continuous aggregates.

**Princípio operacional:** a remoção de chunks brutos antigos só é segura porque o histórico
já foi **materializado** nos CAggs (padrão *downsample-and-keep* da Sprint 02). `drop_chunks`
é uma operação de **metadados** (atômica, barata, sem `VACUUM` pesado) — libera o storage do
chunk inteiro de uma vez. Os CAggs vivem numa hypertable **separada** e **permanecem
intactos**.

> ⚠️ **Destrutivo.** A seção *Validação read-only* é segura ao vivo (`make
> runbook-storage-check`). O `drop_chunks` da seção *Execução* **apaga dados brutos** —
> rodar só em manutenção, após os checkpoints, com backup recente.

---

## 0. Contexto da arquitetura (Sprint 02 — por que isto é seguro)

| Política | Valor | Efeito |
|---|---|---|
| Compressão | chunks > **7 dias** | colunar; leitura histórica barata, DML pontual cara |
| Retenção **raw** | **90 dias** (`policy_retention`, **PAUSADA** neste ambiente — *demo guard*) | em produção dropa chunks brutos > 90d automaticamente |
| Retenção **CAggs** | **2 anos** | preserva os agregados muito além da janela bruta |
| Refresh dos CAggs | contínuo | materializa o histórico **antes** de a retenção tocar a raw |

A salvaguarda central: **retenção dos CAggs (2 anos) > horizonte removido da raw (6 meses)**
**e** os CAggs **já materializaram** o período. Em produção o `policy_retention` faz isto
sozinho; aqui ele está pausado de propósito (para o seed sobreviver à defesa), então a
liberação de storage é uma **intervenção manual** — exatamente este runbook.

---

## 1. Pré-requisitos

- [ ] **Backup recente** validado (`make backup` — ver `backup/README.md`).
- [ ] Janela de manutenção combinada (a operação é online, mas comunique — §6).
- [ ] Acesso com privilégio para `drop_chunks` / `decompress_chunk`.
- [ ] Storage livre suficiente **se** houver sanitização LGPD antes do descarte (a
      descompressão de um chunk infla ~5–20×; ver §4).

## 2. Validação read-only (segura ao vivo) — `make runbook-storage-check`

Executa `runbook-storage-check.sql` (somente leitura). Confirme, **antes de remover nada**:

1. **Tamanho atual** da hypertable e do banco (linha de base do "92%"):
   ```sql
   SELECT pg_size_pretty(hypertable_size('transactions'))      AS hypertable,
          pg_size_pretty(pg_database_size(current_database()))  AS database;
   ```
2. **Chunks-alvo** (mais velhos que 6 meses) e se estão **comprimidos**:
   ```sql
   SELECT show_chunks('transactions', older_than => INTERVAL '6 months');
   SELECT count(*) FILTER (WHERE is_compressed)     AS comprimidos,
          count(*) FILTER (WHERE NOT is_compressed) AS nao_comprimidos
     FROM timescaledb_information.chunks
    WHERE hypertable_name = 'transactions'
      AND range_end < now() - INTERVAL '6 months';
   ```
3. **Cobertura dos CAggs** sobre o período-alvo (o histórico **já foi materializado**?):
   ```sql
   -- O bucket mais ANTIGO de cada CAgg deve ser <= o início da janela a remover.
   SELECT 'cagg_volume_by_type_hourly' AS cagg,
          min(bucket)::text AS bucket_min, max(bucket)::text AS bucket_max
     FROM cagg_volume_by_type_hourly
   UNION ALL
   SELECT 'cagg_settlement_by_institution_daily',
          min(bucket)::text, max(bucket)::text
     FROM cagg_settlement_by_institution_daily;
   ```
4. **Jobs de compressão/retenção** ativos e saudáveis:
   ```sql
   SELECT j.job_id, j.proc_name, j.scheduled, s.last_run_status, s.last_successful_finish
     FROM timescaledb_information.jobs j
     LEFT JOIN timescaledb_information.job_stats s USING (job_id)
    WHERE j.hypertable_name = 'transactions'
    ORDER BY j.job_id;
   ```
   > Espera-se ver `policy_compression` (scheduled) e `policy_retention` (**scheduled=false**
   > — o *demo guard*). Em produção, `policy_retention` estaria `scheduled=true`.

**Critério para prosseguir:** chunks-alvo existem e estão comprimidos; CAggs cobrem o
período (bucket_min ≤ início da janela); backup recente OK.

## 3. Execução — liberar storage (`drop_chunks`)

```sql
-- 3.1 Liste exatamente o que será removido (registre a saída no ticket de manutenção).
SELECT show_chunks('transactions', older_than => INTERVAL '6 months');

-- 3.2 Remova os chunks brutos antigos. Metadados-only: rápido, sem VACUUM pesado.
--     Os CAggs (hypertable separada, retenção 2 anos) NÃO são afetados.
SELECT drop_chunks('transactions', older_than => INTERVAL '6 months');
```

> Em produção, isto é o que o `policy_retention` (90d) faz automaticamente. O runbook
> manual cobre o cenário de **pressão de storage** exigindo remoção além/antes da política.

## 4. Sanitização LGPD antes do descarte (quando aplicável)

Se a regra exigir **trilha de sanitização** de PII antes de descartar (ex.: solicitação de
esquecimento que coincide com o período), aplique o procedimento da Sprint 02
(`desafio-1/queries/lgpd_sanitization.sql`) **antes** do `drop_chunks`:

1. `decompress_chunk('<chunk>')` (escopado ao chunk do titular).
2. `UPDATE`/`DELETE` da PII (`metadata - 'cpf' - 'holder_name'`).
3. `compress_chunk('<chunk>')` (recomprime — limita a janela descomprimida).
4. Registrar trilha de auditoria; **só então** `drop_chunks`.

> Na nossa modelagem a PII vive em `accounts` (dimensão pequena, não comprimida) e a
> hypertable só carrega UUIDs substitutos — então o esquecimento normalmente é um `UPDATE`
> O(1) em `accounts`, **sem** tocar nos chunks. A descompressão acima é o *fallback* para
> PII que tenha vazado para `metadata`.

## 5. Checkpoints de validação (depois)

```sql
-- 5.1 Storage liberado (compare com a §2.1).
SELECT pg_size_pretty(hypertable_size('transactions'))     AS hypertable,
       pg_size_pretty(pg_database_size(current_database())) AS database;

-- 5.2 Chunks antigos sumiram (deve retornar 0 linhas).
SELECT show_chunks('transactions', older_than => INTERVAL '6 months');

-- 5.3 Integridade dos CAggs — as contagens NÃO mudam (agregados preservados).
SELECT count(*) FROM cagg_volume_by_type_hourly;
SELECT count(*) FROM cagg_settlement_by_institution_daily;
```

**Critério de sucesso:** `hypertable_size` caiu; chunks-alvo = 0; **contagens dos CAggs
inalteradas**; queries de tendência (2 anos) continuam respondendo.

## 6. Plano de rollback

| Situação | Ação |
|---|---|
| Removeu chunks além do previsto | **Restore do backup** (`backup/recovery-demo.sh` / restore seletivo do range) e re-injetar apenas o período removido a mais |
| CAgg parece inconsistente após a operação | `CALL refresh_continuous_aggregate('<cagg>', '<inicio>', '<fim>')` para re-materializar o range (a partir do raw remanescente ou do backup restaurado) |
| Dúvida antes de dropar | **Não drope.** Rode a §2 de novo; só prossiga com CAggs cobrindo o período e backup recente |

> Como `drop_chunks` é irreversível sobre o raw, o **backup é o único rollback real** dos
> dados brutos. Os CAggs, por terem retenção 2 anos, são o backup *de fato* dos agregados.

## 7. Comunicação para stakeholders

**Início** (Data Champions + liderança):
> 🛠️ *Manutenção de storage iniciada (HH:MM UTC).* Removendo chunks brutos > 6 meses da
> `transactions` para liberar espaço (storage em 92%). **Sem impacto** em dashboards/relatórios
> de tendência (servidos pelos continuous aggregates, retenção 2 anos). Janela bruta detalhada
> < 6 meses **não** é afetada. ETA: ~X min.

**Progresso** (se demorar):
> ⏳ *Em andamento.* Chunks-alvo identificados e validados contra os CAggs; backup confirmado.
> Liberação de storage em curso.

**Conclusão:**
> ✅ *Concluído (HH:MM UTC).* Storage de NN% → MM%. CAggs íntegros (contagens inalteradas),
> queries de 2 anos validadas. Sem downtime. Detalhe de < 6 meses preservado.

---

## Resumo executável

```bash
make runbook-storage-check     # §2 — validação READ-ONLY (segura ao vivo)
# --- a partir daqui, só em manutenção, após os checkpoints e com backup recente ---
make psql-ts                   # §3 — drop_chunks('transactions', older_than => INTERVAL '6 months')
make runbook-storage-check     # §5 — confirmar storage liberado + CAggs íntegros
```

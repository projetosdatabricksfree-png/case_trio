# Recovery — demonstração validada (TimescaleDB)

> Sprint 06 · Story 6.2 · Desafio 3 / Parte A.
> Pergunta-guia: *"Perdeu dados de um período. Mostre o backup, a perda e a recuperação,
> com contagens e timestamps."*

Escolhemos o **TimescaleDB** por ser o mais ilustrativo (hypertable + chunks comprimidos).
O ciclo é **não-destrutivo no fim**: re-injeta exatamente o que apagou. Roda via
`make recovery-demo` (script `recovery-demo.sh`, reutilizado pelo CI).

## Dois níveis de backup/restore

| Nível | Backup | Quando usar |
|---|---|---|
| **Banco inteiro** | `pg_dump -Fc` (`make backup`) | DR de perda total; restore via `timescaledb_pre_restore()` → `pg_restore` → `timescaledb_post_restore()` (ver [`README.md`](README.md)) |
| **Período (granule)** | COPY binário do range | **recovery rápido e seletivo** de uma janela perdida — é o que esta demo exercita |

**Por que recovery de período aqui (e não restore do dump inteiro):** a hypertable é
**comprimida**. Restaurar o `pg_dump -Fc` completo de chunks comprimidos é frágil (ordenação
entre chunks e catálogo interno). O caminho **rápido e determinístico** para recuperar uma
janela é restaurar **só aquele período** a partir de um granule lógico — um `COPY` binário,
que faz round-trip exato (numeric/jsonb/timestamptz) e funciona **mesmo em chunk comprimido**
(o TimescaleDB 2.x descomprime implicitamente os batches afetados no `DELETE`/`INSERT`).

## Ciclo demonstrado

1. **Backup do período** (granule de recovery): `\copy (SELECT * FROM transactions WHERE
   created_at ∈ janela) TO ... WITH (FORMAT binary)`.
2. **Perda:** `DELETE` da janela → contagem da janela = 0.
3. **Recovery:** `\copy transactions FROM granule WITH (FORMAT binary)` (sem conflito de PK —
   as linhas foram deletadas).
4. **Validação:** contagem da janela **e** total voltam ao valor original.

## Saída observada (seed smoke ~20k)

```
== Demo de recovery TimescaleDB (perda -> recovery seletivo de período) ==
  janela-alvo: [2026-06-19 00:00:00+00, 2026-06-20 00:00:00+00)
  [00:43:37Z] ANTES: total=20000 · janela=71
  [1/3] backup do período -> /tmp/recovery_window_<ts>.bin (COPY binary)
  [2/3] perda: DELETE da janela
  [00:43:40Z] PERDA: total=19929 · janela=0 (perdidas=71)
  [3/3] recovery: restaura o período do granule
  [00:43:42Z] DEPOIS: total=20000 · janela=71

OK: recovery validado — janela e total voltaram ao estado original.
```

> Os números exatos variam com o tamanho do seed; o invariante validado é
> **`janela_depois == janela_antes`** e **`total_depois == total_antes`**.

## RTO / RPO observados e melhorias em produção

| Métrica | Neste ambiente (demo) | Produção (alvo) |
|---|---|---|
| **RPO** (perda máx. de dados) | = idade do último backup (full diário → até 24h) | **segundos** com WAL archiving / PITR; ~5 min com snapshots automáticos |
| **RTO** (tempo de recuperação) | **segundos** (restore só do período) | minutos com PITR gerenciado; restore paralelo de snapshot |

**Como melhora em produção:**
- **PITR via WAL archiving** (self-managed) ou **snapshots automáticos + PITR** do RDS/Aurora
  → RPO de segundos, recovery a qualquer ponto no tempo.
- **Timescale Cloud:** backup contínuo gerenciado; restore de branch/fork para validação sem
  tocar produção.
- **Granule por período** (como nesta demo) mantém o **RTO baixo** em hypertables grandes:
  recupera-se só a janela afetada, sem restaurar o banco inteiro.
- Backups em **S3 com cross-region** garantem recovery mesmo em falha de região.

Ver estratégia completa de backup em [`README.md`](README.md); remoção de chunks antigos
para liberar storage em [`../runbook.md`](../runbook.md).

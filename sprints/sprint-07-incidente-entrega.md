# Sprint 07 — Incidente & Entrega

> **Dia:** 7 · **Peso:** Comunicação e Liderança (15%) + empacotamento · **Stories:** 5
> **Cobre:** RF-5.6 · **Desafio 3 (Parte C)** + estrutura de entrega + apresentação
> **Objetivo:** Resposta escrita ao incidente SEV-1 (árvore de hipóteses, investigação, resolução, pós-incidente, comunicação), README raiz polido, REPORTs finais e roteiro de apresentação ao vivo.

---

## Contexto

Última sprint: consolida a entrega e a nota de Comunicação/Liderança (15%). A resposta ao incidente SEV-1 é um exercício de **raciocínio diagnóstico sob pressão** — o avaliador quer ver árvore de hipóteses ordenada por probabilidade considerando os dois eventos da noite anterior (manutenção no TimescaleDB **e** mudança de security group). O empacotamento garante que *"se não está documentado, não existe"* não derrube a nota.

**Depende de:** todas as sprints anteriores (referencia dashboards, runbooks, arquitetura).
**Habilita:** a apresentação técnica ao vivo.

---

## Definition of Done da Sprint

- [ ] `incident-response.md` completo (investigação, 5+ hipóteses ordenadas, resolução, pós-incidente, comunicação).
- [ ] README raiz polido (setup, arquitetura, índice de entregáveis, como demonstrar cada parte).
- [ ] REPORTs e docs revisados e consistentes entre si.
- [ ] Repositório organizado conforme estrutura sugerida; `docker compose up -d` validado do zero.
- [ ] Roteiro de apresentação (demo script) cobrindo as perguntas esperadas.

---

## Story 7.1 — Resposta ao incidente SEV-1 (volume zero no ClickHouse)

**Descrição:** Documento detalhado de resposta ao incidente. **(Considerar Opus — é o entregável de raciocínio mais valorizado.)**

**Cenário dado:** 06h47 BRT, dashboards Pix no Grafana (ClickHouse) mostram volume **ZERO** nas últimas 2h; aplicações que consultam ClickHouse retornam dados desatualizados; TimescaleDB processa transações normalmente. Na noite anterior: manutenção programada no TimescaleDB (compressão de chunks) **e** atualização de security group na VPC.

**Tarefas — a resposta deve incluir:**

- **Linha de investigação** (o que verificar, em que ordem, comandos/queries, logs/métricas AWS):
  1. Confirmar o sintoma: TimescaleDB tem dados recentes? (`SELECT max(created_at) FROM transactions`) → sim. ClickHouse tem dados recentes? (`SELECT max(created_at) FROM transactions`) → não, parou há ~2h.
  2. **Isolar a camada:** o problema é no pipeline (não chega dado) ou no ClickHouse (chega mas não aparece)? Verificar última execução/lag do pipeline no dashboard (Sprint 06).
  3. Checar saúde/logs do pipeline: está rodando? Travado? Erro de conexão?
  4. Testar conectividade pipeline → TimescaleDB e pipeline → ClickHouse (a mudança de SG pode ter cortado uma das pontas).
  5. Logs do ClickHouse (inserts pararam? merges travados?) e do pipeline (exceptions, timeouts).
  6. Correlacionar com a janela de manutenção e a mudança de SG (timeline AWS via CloudTrail/CloudWatch).

- **Árvore de hipóteses (5+, ordenada por probabilidade)** — considerando manutenção no TimescaleDB **E** mudança de SG:
  1. **Security group bloqueou o pipeline** (porta do TimescaleDB ou do ClickHouse) — coincide com o horário e é a causa mais provável dado o sintoma "TS ok, pipeline parou". *(mais provável)*
  2. **Pipeline travou/morreu** durante a janela de manutenção (conexão derrubada na compressão, sem restart, watermark parado).
  3. **Compressão de chunks** interferiu na leitura incremental do pipeline (se dependesse de algo afetado por compressão; com micro-batch por `updated_at` é menos provável, mas avaliar).
  4. **Mudança de SG isolou o ClickHouse** dos consumidores/inserts (inserts falhando silenciosamente, DLQ enchendo).
  5. **Credenciais/IAM/SSL** alterados na manutenção quebrando a autenticação do pipeline.
  6. (cauda) ClickHouse com merges/disco travado fazendo inserts falharem; ou relógio/timezone causando janela vazia aparente.

- **Resolução da hipótese mais provável (SG bloqueando pipeline):**
  - Verificar regras do SG (inbound/outbound) afetando a porta 5432 (TS) ou 8123/9000 (CH) a partir do host do pipeline (via console/CLI: `aws ec2 describe-security-groups`).
  - Identificar a regra removida/alterada; restaurar o acesso (re-adicionar regra de inbound da subnet/SG do pipeline).
  - Validar conectividade; reiniciar o pipeline; confirmar que o lag drena e o volume volta no Grafana.
  - Comandos concretos (testes de porta, restart do serviço, query de validação de `max(created_at)` convergindo).

- **Ações pós-incidente (preventivo, não só detectivo):**
  - Alerta de **lag/última execução do pipeline** (já previsto na Sprint 06) com threshold agressivo — teria detectado em minutos, não 2h.
  - Alerta de **volume zero em horário comercial** (SEV-1).
  - Mudanças de SG via IaC com revisão e validação de conectividade pós-change (canary/health check automático após alterações de rede).
  - Restart policy + healthcheck do pipeline; auto-recover.
  - Runbook específico "ClickHouse com dados stale" linkado ao alerta.
  - Janela de manutenção com checklist de validação de pipelines downstream antes de encerrar.

- **Comunicação para os times afetados (durante e após):**
  - Durante: aviso inicial em canal de incidentes (impacto, times afetados — comercial sem volume RT, financeiro sem reconciliação intraday, painel de operações stale), ETA, owner.
  - Updates periódicos (ex: a cada 15–30 min) com progresso.
  - Após: resolução, causa raiz, ações preventivas, post-mortem agendado (blameless).

**Critério de aceitação:** documento detalhado cobrindo os 5 itens; hipóteses ordenadas e justificadas considerando os DOIS eventos; resolução com comandos; preventivos concretos; comunicação estruturada.

**Artefatos:** `desafio-3/incident-response.md`.

---

## Story 7.2 — Revisão de consistência da documentação

**Descrição:** Garantir que todos os docs estão coerentes entre si e completos.

**Tarefas:**
- Revisar e cross-check:
  - `desafio-1/REPORT.md` — todas as queries com EXPLAIN antes/depois, justificativas de índice/particionamento, parte ClickHouse, seção LGPD.
  - `desafio-1/migration-analysis.md` — consistente com o dashboard pró-migração (Sprint 06) e com o ADR.
  - `desafio-2/ADR.md` e `desafio-2/diagrams/` — consistentes com o pipeline implementado.
  - `desafio-3/runbook.md`, `recovery-demo.md`, `alerts.md`, `incident-response.md`.
- Verificar que decisões citadas (ex: chunk interval, engine ClickHouse, abordagem do pipeline) aparecem com a **mesma justificativa** em todos os lugares.
- Corrigir referências quebradas, comandos desatualizados, nomes divergentes.

**Critério de aceitação:** documentação internamente consistente; nenhuma contradição entre ADR, REPORTs e runbooks.

**Artefatos:** docs revisados (sem novos arquivos necessariamente).

---

## Story 7.3 — README raiz e índice de entregáveis

**Descrição:** README raiz que serve de porta de entrada para o avaliador.

**Tarefas:**
- README raiz com:
  - Visão geral (1 parágrafo) + diagrama de arquitetura (link/embed).
  - Setup completo: pré-requisitos, `.env`, `docker compose up -d`, ordem de execução dos seeds/pipelines.
  - **Índice de entregáveis** mapeando cada parte do desafio ao arquivo/comando que a demonstra (tabela: Desafio/Parte → Artefato → Como rodar).
  - Seção "Como demonstrar" — passo a passo para reproduzir cada resultado (seed, queries, pipeline, dashboards, API, backup/recovery).
  - Decisões-chave resumidas (com link para ADR/REPORTs).
  - Troubleshooting.

**Critério de aceitação:** seguindo só o README, o avaliador sobe o ambiente do zero e localiza/reproduz cada entregável.

**Artefatos:** `README.md` (raiz, versão final).

---

## Story 7.4 — Validação end-to-end do repositório

**Descrição:** Prova final de que tudo sobe e roda do zero.

**Tarefas:**
- Em ambiente limpo (`docker compose down -v`):
  - `docker compose up -d` → todos `healthy`.
  - Rodar seeds → volume relevante populado.
  - Rodar pipeline → dados em ClickHouse; rodar 2x → sem duplicatas.
  - Abrir Grafana → dashboards com dados (especialmente ClickHouse).
  - Chamar a API → JSON real.
  - Rodar backup → artefatos gerados; rodar recovery-demo → contagens batem.
- Cronometrar e anotar o tempo total de bootstrap (útil para a apresentação).
- Corrigir qualquer quebra encontrada.

**Critério de aceitação:** ciclo completo do zero valida todos os critérios mínimos de aceitação do desafio.

**Artefatos:** checklist de validação preenchido (pode ir no README ou em `docs/`).

---

## Story 7.5 — Roteiro de apresentação (demo script)

**Descrição:** Preparar a apresentação ao vivo de 30–45 min (terminal + dashboards, sem slides obrigatórios).

**Tarefas:**
- Roteiro cobrindo a estrutura pedida:
  1. Demonstrar ambiente rodando (`docker compose up`, dados carregados, queries executando, pipeline, dashboards).
  2. Apresentar decisões arquiteturais e de modelagem, trade-offs e alternativas.
  3. Discutir o cenário de incidente (árvore de hipóteses + resolução).
- **Preparar respostas para as perguntas-âncora da apresentação:**
  - *"E se o volume triplicasse, o que mudaria na arquitetura?"* → micro-batch→CDC, sharding ClickHouse, ajuste de chunks, read replicas (ver ADR).
  - *"Como adicionar um novo consumer no ClickHouse sem impactar os existentes?"* → nova MV/tabela destino + grants; sem tocar pipeline/tabelas atuais; explicar isolamento.
  - *"Como migrar a engine de uma tabela ClickHouse em produção sem downtime?"* → criar nova tabela com engine destino + MV de backfill + dual-write/INSERT SELECT + `RENAME TABLE` atômico (swap); validar e descartar a antiga.
  - *"Estratégia para onboardar um Data Champion novo no Grafana?"* → datasource read-only, dashboards/MVs prontos, dictionaries para nomes amigáveis, guia de boas práticas de query (filtrar por partição/ORDER BY), governança.
  - *"Migrar o PostgreSQL legado para Aurora amanhã — plano de 72h?"* → ver `migration-analysis.md`: replicação lógica, validação paralela, cutover por connection string, rollback.
- Sequência de comandos prontos para colar (evitar improviso ao vivo).
- Antecipar: *"queremos profundidade real, não output de LLM"* — garantir domínio de cada decisão.

**Critério de aceitação:** roteiro com sequência de demo + respostas preparadas para as 5 perguntas-âncora.

**Artefatos:** `docs/presentation-script.md`.

---

## Riscos da Sprint

| Risco | Mitigação |
|---|---|
| Incident response raso (hipóteses sem ordem/justificativa) | Ordenar por probabilidade ligando aos 2 eventos da noite |
| Docs inconsistentes entre si | Story 7.2 de cross-check |
| Ambiente não sobe do zero no dia da entrega | Story 7.4 valida `down -v` → `up -d` |
| Travar em pergunta na apresentação | Demo script com respostas preparadas |
| README incompleto | Índice de entregáveis mapeando desafio→artefato |

---

## Encerramento

Com a Sprint 07 concluída, o desafio está entregue: ambiente reproduzível, três desafios cobertos, documentação como cidadã de primeira classe, e apresentação preparada. Revisar uma última vez contra o **Definition of Done do projeto** (`PRD.md` §10) antes de submeter o repositório.

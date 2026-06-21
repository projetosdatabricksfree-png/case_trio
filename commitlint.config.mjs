// =============================================================================
//  Conventional Commits — monorepo Trio Data Challenge
//
//  Mantém o rigor para commits humanos (extends config-conventional), mas
//  IGNORA commits gerados por bots. O Dependabot escreve "Bump X from A to B"
//  (subject capitalizado) e assina "Signed-off-by: dependabot[bot]" — isso
//  viola a regra `subject-case` por design. Não vamos brigar com o bot:
//  os PRs de atualização de dependência passam no Commit Lint sem afrouxar
//  a regra para pessoas.
//
//  Substitui o antigo .commitlintrc.yml (YAML não expressa funções de ignore).
//  O wagoid/commitlint-github-action carrega este arquivo por padrão.
// =============================================================================
export default {
  extends: ['@commitlint/config-conventional'],
  ignores: [
    (message) => message.includes('dependabot[bot]'),
    (message) => /^Bump .+ from .+ to .+/.test(message),
  ],
};

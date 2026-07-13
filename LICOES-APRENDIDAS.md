# Lições aprendidas — OpenClaw no WSL Containers (Cerbero)

Registro técnico de tudo que foi descoberto durante a primeira instalação
funcional (pioneira, na época) do OpenClaw dentro do **WSL Containers**
(`wslc.exe`, preview público desde 30/06/2026). Serve como memória do
projeto: se algo quebrar de novo, comece por aqui antes de reinvestigar do
zero.

Complementa o `README.md` (que é o guia de uso). Este arquivo é o "porquê"
por trás das decisões do `README.md` e dos scripts.

## 1. A causa-raiz mais importante: virtiofs e bind mounts do Windows

Praticamente metade dos bugs desta sessão têm a mesma origem: o WSLC monta
pastas do Windows dentro da VM Linux via **virtiofs**, e esse mecanismo tem
duas lacunas sérias em relação a um filesystem Linux de verdade:

1. **Permissões**: qualquer arquivo dentro de um bind mount de pasta do
   Windows aparece como `mode=777` dentro do container — o NTFS não tem bits
   de permissão Unix reais pra mapear. O próprio OpenClaw bloqueia por
   segurança qualquer plugin carregado de um caminho world-writable
   (`blocked plugin candidate: world-writable path`).
2. **Locking**: `flock`/`fcntl` (usados por sqlite pra bloqueio de arquivo)
   não funcionam de forma confiável sobre esse tipo de bind mount.

Isso se manifestou em **3 lugares distintos** ao longo do projeto, cada um
achado por um erro diferente:

| Sintoma | Caminho afetado | Causa |
| --- | --- | --- |
| `blocked plugin candidate: world-writable path` | `~/.openclaw/npm/` | Plugins npm instalados em runtime |
| `Failed to update auth profile store; the auth store lock may be busy` | `~/.openclaw/agents/` | sqlite do auth-profile-store |
| `skipped permission hardening ... EPERM: operation not permitted, chmod` | `~/.openclaw/state/` | sqlite do state principal |

Também apareceu uma 4ª vez, mais sutil: instalar o plugin do WhatsApp via
ClawHub falha do mesmo jeito, só que no caminho `~/.openclaw/extensions/`
(ClawHub instala aí, não em `npm/`).

### Solução: volumes nomeados

Em vez de bind-mount de pasta do Windows, usamos **volumes nomeados do WSLC**
(`wslc volume create <nome>`), que vivem dentro do ext4 real da VM do WSLC —
permissões Unix reais, locking real, sobrevivem a `wslc container rm` e
rebuild de imagem. Não aparecem navegáveis no Explorer do Windows (trade-off
aceito).

Volumes criados: `cerbero-npm`, `cerbero-agents`, `cerbero-extensions`,
`cerbero-state` — montados nos 4 caminhos da tabela acima (mais
`extensions/`).

**Detalhe importante**: volumes novos nascem com dono `root`, e o dono às
vezes reseta pra `root` entre execuções (aconteceu depois de instalações de
plugin que falharam/limparam arquivo parcialmente — suspeita: comportamento
do Docker/WSLC de "volume parece vazio → recopia da imagem e reseta
ownership"). Por isso o fix não foi "chown uma vez", foi **chown antes de
toda invocação** (função `Repair-VolumeOwnership` no
`setup-cerbero-wslc.ps1`, chamada tanto antes do bootstrap quanto antes de
subir o gateway).

## 2. Bugs de quoting do PowerShell 5.1 ao chamar exe nativo

`wslc.exe` (e por extensão `openclaw` dentro do container) é um executável
nativo, não um cmdlet. PowerShell 5.1 tem **duas** falhas de marshalling de
argumento diferentes ao montar a linha de comando pra um exe nativo a partir
de um array de strings:

1. **Engole aspas duplas embutidas.** Um elemento de array como
   `'{"key":"value"}'` chega no processo nativo sem as aspas internas —
   quebra qualquer JSON passado como argumento posicional
   (`config set <path> <json>`).
2. **Quebra o argumento no espaço**, mesmo dentro de um valor que deveria
   estar "protegido". Isso só apareceu quando começamos a usar aliases com
   espaço (`"Opus 4.8"`, `"3.1 Flash-Lite"`) — o openclaw reclamava
   `Too many arguments for this command`, sinal de que o JSON tinha chegado
   partido em múltiplos argumentos.

### Tentativa intermediária (funcionou parcialmente)

Pro bug 1, o workaround foi escapar aspas internas como `\"` em vez de `"`
dentro de strings **single-quoted** do PowerShell (`'{\"key\":\"value\"}'`).
Isso resolveu JSON sem espaço nos valores (ex.: `channels.whatsapp`,
`plugins.allow`, os aliases originais `ds`/`flash`/`haiku`).

Mas não resolveu o bug 2 — qualquer alias com espaço continuava quebrando.

### Solução definitiva: `config patch --file`

O CLI do próprio OpenClaw tem `openclaw config patch --file <caminho>`, que
lê o JSON5 de um **arquivo**, não de argumento de linha de comando — elimina
os dois bugs de uma vez, porque nada passa pelo parser de argumento nativo do
PowerShell. `config patch` faz merge recursivo de objetos automaticamente
(não precisa de `--merge` feito na mão).

Desde então, todo o bootstrap de config complexo (aliases de modelo, gateway,
canal WhatsApp, `plugins.allow`) virou **um único arquivo
`bootstrap.patch.json5`**, escrito pelo próprio `setup-cerbero-wslc.ps1` via
`Set-Content` (sem tocar em exe nativo) e aplicado com:

```powershell
openclaw config patch --file /home/cerbero/.openclaw/bootstrap.patch.json5
```

**Regra prática pra qualquer config futura com valor complexo (JSON, espaço,
aspas): usar `config patch --file`, nunca `config set <path> <json-inline>`.**

## 3. Bug de binding posicional de parâmetro do PowerShell

Regra pouco conhecida: declarar `[Parameter(Position=N)]` em **qualquer**
parâmetro de um `param()` block desliga a numeração posicional automática
de **todos os outros** parâmetros não decorados do mesmo script.

Isso quebrava `cerbero-cli.ps1 models status` silenciosamente: sem um
`Position` explícito no parâmetro `$Args`, o PowerShell tentava usar posição
automática pros parâmetros `$BaseDir`/`$ImageTag` também, e `"models"` virava
o valor de `$BaseDir`, `"status"` virava `$ImageTag`, e `$Args` ficava vazio
— resultando em erros tipo `Imagem 'list' não encontrada`.

Fix: `[Parameter(Position = 0, ValueFromRemainingArguments = $true)]` só no
parâmetro `$Args`.

## 4. Particularidades do `wslc.exe` (preview)

- **Sem `--format`** (Go template) em `container list`/`volume list`. Não dá
  pra filtrar por nome formatado como no Docker CLI.
- **Sem subcomando `restart`.** Só `stop` + `start` separados.
- **`wslc system session terminate`** reseta a sessão/VM inteira — mais
  cirúrgico que `wsl --shutdown` quando a rede da VM trava (aconteceu uma vez
  com pull de imagem falhando; esse comando resolveu).
- **Rede (consomme)**: não relaia multicast/broadcast (mDNS/Bonjour/SSDP/UPnP),
  não repassa ICMP, traceroute parcial, GRE/ESP/SCTP descartados — por isso
  `OPENCLAW_DISABLE_BONJOUR=1` no config.
- **Containers descartáveis não compartilham namespace de rede** com um
  container de longa duração já rodando. Comandos que precisam falar com o
  gateway "ao vivo" (`channels status`, `gateway status`, `dashboard`) falham
  via `cerbero-cli.ps1` com algo como `Gateway not reachable: gateway closed
  (1006 abnormal closure)`. Rodar via
  `wslc container exec cerbero-gateway openclaw <comando>` em vez disso.
- **CMD do Dockerfile precisa do subcomando completo**: `node dist/index.js
  gateway --bind lan --port 18789`. Sem o subcomando `gateway`, o processo cai
  num modo de onboarding interativo que exige TTY e trava o container.

## 5. Metodologia vencedora: tudo via CLI do próprio `openclaw`

Descoberta empírica do usuário, confirmada depois pelo `docker-compose.yml`
oficial do OpenClaw (fluxo "manual" recomendado na doc): a maior taxa de
sucesso vem de **não** pré-escrever `openclaw.json` na mão e só montar —
vem de deixar o próprio `openclaw` gerar/mutar a config via CLI
(`onboard`, `config set`, `config patch`) depois que o container já existe.

Isso evitou de vez um bug que travou bastante tempo no início: escrever um
`openclaw.json` comentado (JSON5) e deixar o CLI reescrever por cima disparava
`Config write rejected: ... size-drop:X->Y` — o mutator do próprio OpenClaw
rejeitava a escrita porque a remoção dos comentários (JSON5 → JSON) parecia
um clobber destrutivo. Config 100% gerada pelo CLI nunca tem esse problema
porque nunca teve comentário pra perder.

Sequência que funciona, na ordem certa (implementada em
`setup-cerbero-wslc.ps1`): build → cria/chown volumes nomeados → autentica os
3 provedores (`onboard --non-interactive`) → define prioridade de modelo
(`models set`/`models fallbacks`) → aplica `bootstrap.patch.json5` (aliases,
gateway, WhatsApp, `plugins.allow`) → instala plugin do WhatsApp → chown de
novo → sobe o gateway.

## 6. Catálogo de modelos do OpenClaw: nem tudo que existe aparece no `list`

`openclaw models list --all --provider <id>` **não é** a lista completa do
que a API do provedor realmente aceita — é só o catálogo estático empacotado
no manifesto do plugin daquela versão do OpenClaw, que pode estar
desatualizado. Confirmado na doc oficial
(`docs.openclaw.ai/cli/models`): providers marcados `static` usam só esse
catálogo embutido; providers marcados `runtime` (caso de Anthropic e Google)
conversam direto com a API real do provedor usando **qualquer ref válido**
que você configurar — não precisam estar pré-cadastrados em lugar nenhum.

Isso explicou por que `claude-opus-4-8`, `claude-fable-5` e o Gemini
Flash-Lite não apareciam no `models list --all` mesmo funcionando de verdade:
o catálogo embutido do plugin só não tinha sido atualizado com esses refs
ainda.

Refs reais confirmados na doc (`docs.openclaw.ai/providers/anthropic` e
`/providers/google`), além dos que já estavam em uso:

- **Anthropic**: `claude-opus-4-8` (padrão pra mídia/imagem/PDF, contexto 1M),
  `claude-fable-5` (thinking sempre ligado; ver ressalva abaixo),
  `claude-sonnet-5` (o Sonnet mais novo — **não confundir** com
  `claude-sonnet-4-6`, que é uma versão anterior e é o que ficou configurado
  como alias `Sonnet 4.6` neste projeto), `claude-mythos-5` (acesso limitado).
- **Google**: `gemini-3.1-flash-lite` (chat, resposta mais rápida),
  além de `gemini-3.5-flash`/`gemini-3.1-pro-preview` já em uso.

**Ressalva sobre Fable 5**: tem classificador de segurança que pode recusar a
resposta; quando recusa, a Anthropic reencaminha automaticamente pro Opus 4.8
(e cobra na tarifa do Opus) — comportamento documentado
(`server-side-fallback-2026-06-01`), não bug. Vale saber antes de usar em
produção com orçamento apertado.

Esses 4 refs extras foram cadastrados como aliases adicionais (sem virar
`primary`/fallback) no `bootstrap.patch.json5` — ficam disponíveis pra escolha
manual no select da Control UI.

## 7. Prioridade de modelo e aliases (estado atual)

- **Primary**: `deepseek/deepseek-v4-flash` (alias `V4 Flash`)
- **Fallback 1**: `google/gemini-3.5-flash` (alias `3.5 Flash`)
- **Fallback 2**: `anthropic/claude-haiku-4-5` (alias `Haiku 4.5`)
- Extras cadastrados (sem entrar no fallback): `3.1 Pro`, `Sonnet 4.6`,
  `Opus 4.8`, `Fable 5`, `Sonnet 5`, `3.1 Flash-Lite`.

Convenção de nome de alias: igual ao que aparece no app oficial de cada
modelo (sem prefixo de marca — "3.5 Flash", não "Gemini 3.5 Flash" — porque o
próprio app já deixa isso implícito pelo contexto).

## 8. Idempotência: pontos que quebravam em re-execuções

Um script "funciona na primeira vez" é fácil; idempotente (funciona igual da
segunda vez em diante) exigiu 3 correções específicas:

1. **`models fallbacks add`** duplicaria entradas se rodado 2x — sempre
   `fallbacks clear` antes de `add`.
2. **`plugins install clawhub:@openclaw/whatsapp`** falha com
   `plugin already exists ... delete it first` a partir do 2º rebuild, porque
   o volume `cerbero-extensions` persiste. Fix: apagar
   `~/.openclaw/extensions/whatsapp` (via container descartável como root)
   antes de toda instalação.
3. **Healthcheck com uma única tentativa em 3s** dava falso-negativo logo
   após o bootstrap pesado. Fix: até 5 tentativas, 4s entre cada.

**O vínculo do WhatsApp (QR) sobrevive a rebuild** contanto que o volume
`cerbero-agents` não seja apagado — confirmado na prática (`channels status`
mostrou `linked, running, connected` logo após um rebuild completo, sem
precisar escanear o QR de novo).

## 9. Convenções do projeto (recapitulando do README)

- Vocabulário: "wslc"/"container" pra descrever nossa própria infra; "docker"
  só pra referências factuais reais (docker-compose.yml oficial, Docker
  Engine/Hub, formato Dockerfile).
- Nome fixo `cerbero` em todo identificador criado (imagem, container,
  volumes, pasta de dados, scripts) — evita colisão com outros
  containers/projetos WSLC no mesmo host.

## Referências usadas

- `docs.openclaw.ai/cli/models` — comportamento de `models list --all`,
  static vs. runtime, `models scan`.
- `docs.openclaw.ai/cli/config` — modos do `config set`, `config patch
  --file`, write safety.
- `docs.openclaw.ai/providers/anthropic` — refs reais de modelo, ressalva do
  Fable 5, contexto 1M.
- `docs.openclaw.ai/providers/google` — auth, refs de modelo, capacidades.
- `docs.openclaw.ai/providers/models` — quickstart genérico de provider.

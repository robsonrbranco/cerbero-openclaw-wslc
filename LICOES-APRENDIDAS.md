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

## 10. Bugs conhecidos do próprio OpenClaw (não da nossa infra)

Nem todo erro que aparece é culpa do WSLC/virtiofs/PowerShell — o OpenClaw em
si (versão 2026.6.11) tem bugs upstream ativos. Vale distinguir antes de sair
reinvestigando a infra do zero.

### `Error: reply session initialization conflicted for agent:main:main`

Aparece esporadicamente ao conversar pelo WhatsApp (ou qualquer canal).
**Causa**: condição de corrida dentro do próprio OpenClaw — o
`replyResolver` tenta iniciar um novo turno de conversa mas colide com o
estado `running` que ficou preso do turno anterior (duas escritas
concorrentes na mesma entrada de sessão: persistência do transcript +
metadados do runner). Não é causado pela nossa config, pelos volumes
nomeados nem pelo bind mount — é bug de sessão do core, com múltiplos issues
abertos cobrindo webchat, Telegram, Signal e Discord além do WhatsApp:
[#98220](https://github.com/openclaw/openclaw/issues/98220),
[#98741](https://github.com/openclaw/openclaw/issues/98741),
[#100173](https://github.com/openclaw/openclaw/issues/100173),
[#101250](https://github.com/openclaw/openclaw/issues/101250).

O time do OpenClaw já está corrigindo com retry/backoff, portado pra
Slack/Telegram — não confirmado ainda pro WhatsApp na 2026.6.11.

**O que fazer quando acontecer:**

1. Reenviar a mesma mensagem depois de uns segundos - na maioria dos casos é
   só timing, resolve sozinho.
2. Se a mesma conversa continuar travada, `wslc container stop cerbero-gateway`
   + `start` limpa o estado `running` preso em memória (sem precisar
   rebuildar imagem/volumes).
3. Rodar `.\setup-cerbero-wslc.ps1` de vez em quando pega a imagem mais
   recente do `ghcr.io/openclaw/openclaw:latest`, que deve eventualmente
   incluir a correção pro WhatsApp também.

## 11. Incidente real: WhatsApp ficou sem plugin depois de um restart

Aconteceu na prática (14/07/2026): um restart do container disparou
`Plugin "@openclaw/whatsapp" requires plugin API >=2026.7.1, but this
OpenClaw runtime exposes 2026.6.11`. Causa raiz, confirmada no log do
gateway (`update available (latest): v2026.7.1 (current v2026.6.11)`): a
imagem base (`ghcr.io/openclaw/openclaw:latest`) estava com o core numa
versão presa em cache, mais antiga que a exigida pela versão mais recente do
plugin publicada no ClawHub. Como o passo de idempotência do WhatsApp
**apagava o plugin antes de reinstalar**, e a reinstalação falhou por causa
do gap de versão, o canal ficou sem plugin nenhum até o próximo build bom -
sessões do WhatsApp em andamento morreram com `unsupported channel:
whatsapp` / `transcript tail is not resumable`.

**Correções aplicadas:**

1. `wslc build --pull` (em vez de só `wslc build`) - força checar de novo o
   registry pela imagem base, em vez de reusar uma camada antiga em cache
   local. Sem isso, `FROM ghcr.io/openclaw/openclaw:latest` pode ficar preso
   numa versão velha indefinidamente.
2. **Plugin do WhatsApp agora vem pré-instalado na própria imagem**
   (`RUN node dist/index.js plugins install clawhub:@openclaw/whatsapp` no
   Dockerfile) em vez de só ser baixado em runtime. Vantagens: falha CEDO e
   visível (o build para) em vez de quebrar silenciosamente num restart; e um
   volume `cerbero-extensions` novo/vazio já nasce com o plugin funcionando
   (populado automaticamente a partir da imagem no primeiro mount), mesmo se
   o ClawHub estiver fora do ar ou exigindo versão nova bem naquele momento.
3. O bootstrap em runtime agora só **tenta atualizar** o plugin por cima
   (não é mais obrigatório pra funcionar), com **backup/restore seguro**:
   renomeia a pasta existente pra `.bak` antes de reinstalar, e só apaga o
   backup se a reinstalação funcionar - se falhar, restaura o backup em vez
   de deixar o canal sem nada.

### Bug relacionado: `Unknown command: openclaw bash`

A parte do projeto que restaura o `gog` (Google Workspace CLI, adicionada
fora desta conversa) chamava o script `bootstrap-gog.sh` através do mesmo
helper usado pra comandos do openclaw (`--entrypoint node ... dist/index.js
bash <script>`) - mas `bash` não é um subcomando do `openclaw`, é um
script shell puro. Fix: rodar com `--entrypoint bash` direto, nunca através
do CLI do openclaw.

### `openclaw update` não funcionava: `Update skipped: not-git-install`

A imagem oficial instala o OpenClaw globalmente (não via `git clone`), então
o mecanismo de auto-update cai no caminho de "reinstalação global" - que
precisa escrever em pasta do npm que só o `root` pode tocar. Sem `sudo`
instalado (e sem configuração passwordless, já que não há TTY interativo
dentro do container pra digitar senha), o usuário `cerbero` não-root não
consegue completar essa atualização. Fix: `sudo` adicionado ao `apt-get
install` do Dockerfile, com `/etc/sudoers.d/cerbero` configurado
`NOPASSWD:ALL`.

### Regressão: número de WhatsApp voltando pro placeholder sozinho

Ao publicar o projeto no GitHub, o default do parâmetro `-WhatsappNumber` no
`setup-cerbero-wslc.ps1` foi trocado do número real para o placeholder
genérico `+55SEUNUMERO` (pra não vazar dado pessoal no repositório público).
Efeito colateral não previsto na hora: como nada mais fornecia o número real,
todo rebuild sem passar `-WhatsappNumber` explicitamente na linha de comando
voltava a gravar o placeholder em `channels.whatsapp.allowFrom`, quebrando
silenciosamente o allowlist.

**Lição**: qualquer dado pessoal/privado tem que morar no `.env` (nunca
commitado), nunca só como default de parâmetro num script que vai pro
repositório público — um default "seguro pra publicar" e um default "que
funciona de verdade" são coisas diferentes, e um script idempotente precisa
dos dois ao mesmo tempo. Fix aplicado: `WHATSAPP_NUMBER` no `.env` (lido
automaticamente pelo script, com o parâmetro `-WhatsappNumber` como override
manual só se passado explicitamente).

## 12. TTS: timeout de 30s aparecendo mesmo com `messages.tts.timeoutMs` configurado (14/07/2026)

O briefing diário em áudio (`gemini-3.1-flash-tts-preview`) falhava
consistentemente com:

```
[fetch-timeout] fetch timeout after 30000ms ... url=.../gemini-3.1-flash-tts-preview:generateContent
```

A falha derruba o turno em silêncio (`turn dispatched with no queued reply
payloads`) — sem áudio e sem fallback pra texto. O timeout que estourava
aparece no log como `operation=fetchWithSsrFGuard`, um guard genérico de
fetch que pode ter teto próprio de 30s independente da config do TTS (não
confirmado no código-fonte, só inferido pela evidência do log).

**Fix aplicado**: subir `messages.tts.timeoutMs` para `120000` (120s) em
`openclaw.json`. Funcionou — depois da mudança, `Sent media reply` (áudio)
passou a aparecer no log sem mais timeout. **Se o timeout de 30s voltar a
aparecer mesmo com esse valor, o problema não está nessa config e sim no
guard `fetchWithSsrFGuard`.**

Efeito colateral não óbvio: `messages.tts.timeoutMs` não é hot-reloadable —
o gateway detecta a mudança (`[reload] config change detected`) e se
auto-reinicia via SIGTERM pra aplicar. Isso expôs o bug do próximo item.

## 13. Auto-restart pós-SIGTERM é inconsistente — watchdog externo criado (14/07/2026)

Depois de um SIGTERM (de config reload ou outro motivo), o container **às
vezes** volta sozinho e às vezes não:

- 1º evento (19:49): SIGTERM → shutdown limpo → voltou sozinho 3 min depois.
- 2º evento (20:07, gatilho: reload de `messages.tts.timeoutMs`): SIGTERM →
  shutdown limpo → **não voltou sozinho**, ficou `exited` até restart manual
  ~7 min depois.

Não identificamos a causa raiz da inconsistência (fora do escopo investigar
o supervisor do wslc), mas o achado prático é que não dá pra confiar 100% no
auto-recovery durante o período de teste.

**Mitigação — watchdog externo** via Agendador de Tarefas do Windows, a cada
5 min (`scripts/watchdog-cerbero.ps1` + `scripts/register-watchdog-task.ps1`):

- Bate em `http://127.0.0.1:18789/healthz`; se falhar, roda `wslc container
  start cerbero-gateway`.
- Trava anti crash-loop: 3+ restarts em 30 min → para de tentar e só loga
  alerta em `logs/watchdog.log` (evita mascarar um bug real com restart
  infinito).
- Registrado no escopo do usuário (não sobrevive reboot sem login
  automático); rodar mesmo deslogado exigiria "Run whether user is logged on
  or not" + salvar senha do Windows na tarefa — não configurado por padrão.

**Nota de implementação (Agendador de Tarefas)**: `New-ScheduledTaskTrigger
-RepetitionDuration ([TimeSpan]::MaxValue)` falha com `O XML da tarefa
contém um valor formatado incorretamente ou fora do intervalo` — o schema do
Task Scheduler não aceita a duração máxima de um `TimeSpan` do .NET. Fix:
usar uma duração grande porém válida, ex. `(New-TimeSpan -Days 3650)`
(~10 anos). Detalhe à parte: `Register-ScheduledTask` não é
`-ErrorAction Stop` por padrão — sem isso, um erro de registro pode passar
batido e o script seguinte imprimir "sucesso" mesmo a tarefa não tendo sido
criada. Sempre envolver em `try/catch` com `-ErrorAction Stop`.

**Descoberta adicional (mesmo dia, testando troca de provider de TTS)**: o
`ID DO CONTÊINER` de `cerbero-gateway` muda a cada restart disparado por
reload de config (`341ba583f7d7` → `1b7b3bd0b22a` num teste real) — ou seja,
não é "stop + start" do mesmo container, é recriação com ID novo. Isso
explicava o `WSLC_E_CONTAINER_NOT_FOUND` que o watchdog pegava algumas
vezes: se o poll de 5 min caía bem na janela entre o container antigo sumir
e o novo existir, `wslc container start <nome>` não achava nada pra
iniciar. Fix no `watchdog-cerbero.ps1`: até 3 tentativas de `start` com
10s de espera entre elas antes de desistir, e loga `wslc container ps -a`
inteiro quando todas falham (contexto completo pra próxima investigação, em
vez de só "não encontrado"). Também corrigido: `Add-Content` sem
`-Encoding UTF8` corrompia acento na saída do `wslc.exe` no log
(`Contêiner` virava `Cont+ñiner`) — console do PowerShell 5.1 usa codepage
OEM por padrão, não UTF-8.

## 14. PATH explícito no container para `~/.openclaw/extensions`

Adicionada a variável `PATH=/home/cerbero/.openclaw/extensions:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin`
no `$runArgs` do `setup-cerbero-wslc.ps1`, garantindo que binários instalados
em `~/.openclaw/extensions` (onde o ClawHub instala plugins, como o do
WhatsApp — ver seção 1) fiquem resolvíveis via PATH dentro do container.

## 14b. `-WindowStyle Hidden` não é suficiente pra rodar em background de verdade

O watchdog (item 13) rodava via `powershell.exe -WindowStyle Hidden -File
...` direto na ação da tarefa agendada. Na prática, uma janela de console
ainda pisca na tela a cada execução (a cada 5 min) — o `conhost.exe` abre a
janela antes do `-WindowStyle Hidden` ser aplicado, então o parâmetro chega
tarde demais pra evitar o flash.

**Fix**: trocar a ação da tarefa de `powershell.exe` direto para
`wscript.exe //B run-watchdog-hidden.vbs`, onde o `.vbs` chama o
PowerShell via `WScript.Shell.Run(cmd, 0, True)` — o parâmetro de janela
`0` nunca chega a criar uma janela visível, nem por um instante (diferente
de `-WindowStyle Hidden`, que esconde uma janela que já existiu por um
frame). Depois de trocar, é preciso re-registrar a tarefa
(`register-watchdog-task.ps1` de novo, com `-Force`) pra ação nova
substituir a antiga.

## 14c. Grace period pós-boot no watchdog

O serviço do WSLC demora um pouco pra subir depois que o Windows reinicia.
Como a tarefa agendada roda de 5 em 5 min com `-StartWhenAvailable`, um
reboot podia disparar uma checagem "atrasada" bem cedo, com o WSLC ainda não
pronto — o `/healthz` falha (esperado, não é bug), o watchdog tenta
`wslc container start` (que pode nem funcionar ainda), e isso consome
tentativas do contador anti crash-loop por um motivo que não é uma falha de
verdade.

**Fix**: no início do `watchdog-cerbero.ps1`, calcula o uptime da máquina
(`Win32_OperatingSystem.LastBootUpTime`) e, se for menor que
`$StartupGraceSec` (padrão 300s), sai sem checar nada — nem loga como
falha. Não precisa mexer no trigger da tarefa agendada nem saber exatamente
quando o Task Scheduler decidiu rodar o script; funciona em qualquer
cenário de boot (rápido, lento, com catch-up de execução perdida).

## 15. Repositório mapeado dentro do container (leitura+escrita), de propósito (14/07/2026)

Decisão consciente: `setup-cerbero-wslc.ps1` agora monta `C:\wslc\projects\cerbero`
(o repositório, não a pasta de dados) dentro do container em
`/home/cerbero/cerbero-project`, leitura+escrita — parâmetro `-ProjectDir`.
Objetivo: o próprio agente (via chat, usando modelos Claude quando a tarefa
pedir cuidado) consegue ler e editar a infra que ele mesmo roda em cima.

**Risco aceito, não corrigido**: por ser bind mount de pasta do Windows, herda
os mesmos problemas do item 1 (permissão 777, locking não confiável). Na
prática isso significa que `git commit` feito **de dentro do container**
nessa pasta deve travar em `.git/index.lock: Operation not permitted` — o
mesmo bug que travou um commit feito de fora, pelo sandbox do Claude, nesse
mesmo dia. Decidimos não contornar isso, porque funciona como freio natural:
o agente edita o texto dos arquivos, mas versionar (commit/push) continua
sendo um passo manual de fora do container, com humano olhando o diff antes.

**Segundo freio, estrutural, não configurado por nós**: `wslc.exe` só existe
no lado Windows. Um processo dentro do container Linux não tem como chamar
`wslc build`/`container run` pra aplicar as próprias mudanças de
Dockerfile/script — só consegue editar texto. Pior cenário realista de uma
edição ruim: fica parada num arquivo até alguém rodar o setup script de
propósito, nunca um rebuild automático e silencioso.

**Regra dura**: `-ProjectDir` só deve apontar pra pasta de **código-fonte**
(`C:\wslc\projects\cerbero`). Nunca apontar pra pasta de dados (`-BaseDir`,
que tem o `.env` com chaves de API reais) — o mount novo foi desenhado
especificamente pra não tocar em segredo nenhum.

## 16. Dois containers WSLC não se enxergam entre si por padrão (15/07/2026)

Descoberto operando o Cerbero junto com o projeto irmão
[Hermes](../hermes) (n8n): `localhost` de dentro do `cerbero-gateway` aponta
pra ele mesmo, não pro `hermes-n8n` nem pro host Windows — e por padrão os
dois containers WSLC não conseguem se alcançar de forma nenhuma (nem por
nome, nem por IP), mesmo rodando no mesmo host, porque cada `wslc run` sem
`--network` explícito cai numa rede default onde containers não resolvem uns
aos outros.

Investigação completa (arquitetura do `wslc.exe`, por que isso acontece, e a
solução com `wslc network create`/`--network`) documentada no
[LICOES-APRENDIDAS.md do Hermes, seção 5b](../hermes/LICOES-APRENDIDAS.md) —
não duplicado aqui pra não desalinhar as duas cópias no futuro.

**Fix aplicado neste projeto**: parâmetro `-SharedNetwork` (default
`hermes-cerbero-net`) em `setup-cerbero-wslc.ps1`, espelhando o mesmo
parâmetro no `setup-hermes-wslc.ps1`. Depois de rodar os dois setups, de
dentro do `cerbero-gateway` o Hermes fica em `http://hermes-n8n:5678`
(nome do container, porta interna — não a porta publicada no host).

**Independência preservada**: `-SharedNetwork` é opcional (`-SharedNetwork
""` desativa) e cada projeto cria/usa a rede por conta própria — nenhum dos
dois scripts lê, importa ou depende de arquivo do outro projeto. A rede
nomeada só existe se ambos os setups rodarem apontando pro mesmo nome de
rede; não há acoplamento de código, só uma convenção de nome compartilhada
entre quem optar por usá-la.

## 17. `-Hostname`: nome do serviço desacoplado do `-ContainerName`, pensando em migração futura (15/07/2026)

Depois de resolver a lição 16, veio o pedido de acessar
`http://cerbero-gateway:18789` direto do navegador do Windows (não só entre
containers) — e, junto, o requisito de que cada projeto WSLC seja
autossuficiente: script de resolução de nome próprio, não compartilhado
com o Hermes, e um único ponto de configuração que precise mudar no dia de
uma eventual migração para uma infraestrutura na nuvem (domínio real em vez
de nome de container local).

**Fix aplicado**: parâmetro `-Hostname` (default `cerbero-gateway`, igual a
`-ContainerName` mas independente dele) em `setup-cerbero-wslc.ps1`, usado
em três lugares:

1. `--network-alias $Hostname` ao conectar na `-SharedNetwork` (best-effort
   — a doc pública do `wslc network` ainda não confirma exaustivamente esse
   flag nesta preview; se falhar, o container continua alcançável pelo
   `--name` normalmente).
2. `gateway.controlUi.allowedOrigins` no `bootstrap.patch.json5`, que agora
   inclui `http://${Hostname}:18789` além de `localhost`/`127.0.0.1`.
3. Valor default do parâmetro `-Hostname` em `scripts/add-hosts-entries.ps1`
   **próprio deste projeto** (não um script compartilhado com o Hermes — ver
   ressalva abaixo).

**Por que o script de hosts não é compartilhado entre os dois projetos**:
uma versão anterior desta solução mantinha um único
`add-hosts-entries.ps1` só no Hermes, com o Cerbero referenciando esse
caminho no README. Isso quebrava a autossuficiência dos dois pacotes — para
usar o Cerbero sozinho, seria preciso ter o repositório do Hermes clonado
também. Corrigido: cada projeto tem sua própria cópia do script, cada uma
cuidando só da própria entrada no hosts. Pequena duplicação de ~100 linhas
de PowerShell aceita deliberadamente em troca de zero acoplamento entre os
dois pacotes.

## 18. Ferramentas confirmadas disponíveis neste host (15/07/2026)

Registro simples, sem incidente por trás — só para não precisar redescobrir
em sessões futuras: `gh` (GitHub CLI) está instalado e autenticado neste
host, confirmado ao publicar tanto este repositório quanto o do projeto
irmão Hermes via `gh repo create ... --push`. Relevante para qualquer
automação futura que precise interagir com o GitHub (releases, PRs, issues)
sem precisar verificar disponibilidade do zero.

**Nota operacional relacionada**: `git add`/`git commit` rodados de dentro
de um ambiente que acessa este repositório via bind mount tipo virtiofs
(mesma classe de mount documentada na seção 1 deste arquivo) podem travar
em `.git/index.lock: Operation not permitted`, mesmo sendo dono do arquivo —
confirmado na prática ao tentar preparar este commit por essa via. `gh`/`git`
rodados diretamente no PowerShell do Windows (como você fez) não têm esse
problema; é especificamente o caminho "de fora, via mount" que é frágil.
Prefira sempre commitar/publicar direto do PowerShell do host.

## 18. Incidente real: instalação nativa órfã do OpenClaw brigando pela porta 18789 (15/07/2026)

Depois de um reboot do Windows (pra instalar dependências do LM Studio), o
`setup-cerbero-wslc.ps1` parou de conseguir subir o gateway:

```
Falha ao mapear a porta '127.0.0.1:18789/tcp' ...
Código de erro: WSAEADDRINUSE
```

`wslc container ps -a` não mostrava nenhum `cerbero-gateway` — a porta
estava ocupada por algo fora do wslc inteiramente. Diagnóstico:

```powershell
netstat -ano | findstr :18789          # -> PID
Get-Process -Id <PID>                  # -> node.exe, mas de onde?
Get-CimInstance Win32_Process -Filter "ProcessId=<PID>" |
  Select-Object ExecutablePath, CommandLine   # confirma a origem
```

O último comando revelou a causa: `node.exe ...\npm\node_modules\openclaw\dist\index.js
gateway --port 18789` — uma instalação **nativa** do OpenClaw no Windows
(`npm install -g openclaw`), sobra de uma fase anterior do projeto, antes de
adotar o container WSLC. Ela subia sozinha a cada boot via um atalho
`OpenClaw Gateway.vbs` na pasta de Startup do usuário
(`%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup`) — mesmo truque
de "rodar hidden via VBScript" que usamos de propósito no watchdog (item
14b), só que aqui era um resíduo esquecido, não algo desejado. Duas tarefas
agendadas órfãs da mesma fase (`OpenClaw Gateway`, `Cerbero-WSL-Gateway`)
apareciam como `Disabled` — não eram a causa, mas mesmo lixo da época.

**Por que só apareceu agora**: essa instalação nativa sempre existiu, mas o
Windows só a executa no boot — como o computador não tinha sido reiniciado
desde que o container assumiu o papel do gateway, ninguém notou até um
reboot (pelo motivo que fosse) colocar os dois pra brigar pela mesma porta.

**Remoção completa**:
```powershell
Stop-Process -Id <PID> -Force
npm uninstall -g openclaw
Remove-Item "$env:USERPROFILE\.openclaw" -Recurse -Force
Remove-Item "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup\OpenClaw Gateway.vbs" -Force
Unregister-ScheduledTask -TaskName "OpenClaw Gateway" -Confirm:$false
Unregister-ScheduledTask -TaskName "Cerbero-WSL-Gateway" -Confirm:$false
```

**Lição**: ao migrar de uma instalação nativa pra uma containerizada (ou
qualquer mudança de topologia parecida), procurar ativamente por
autostart deixado pra trás (Startup folder, `Win32_StartupCommand`,
registro `...\CurrentVersion\Run`, Scheduled Tasks) faz parte do checklist
de migração — não só desinstalar o software na hora, mas confirmar que
nada vai tentar religá-lo sozinho no próximo boot.

## Referências usadas

- `docs.openclaw.ai/cli/models` — comportamento de `models list --all`,
  static vs. runtime, `models scan`.
- `docs.openclaw.ai/cli/config` — modos do `config set`, `config patch
  --file`, write safety.
- `docs.openclaw.ai/providers/anthropic` — refs reais de modelo, ressalva do
  Fable 5, contexto 1M.
- `docs.openclaw.ai/providers/google` — auth, refs de modelo, capacidades.
- `docs.openclaw.ai/providers/models` — quickstart genérico de provider.
- [github.com/openclaw/openclaw#98220](https://github.com/openclaw/openclaw/issues/98220),
  [#98741](https://github.com/openclaw/openclaw/issues/98741),
  [#100173](https://github.com/openclaw/openclaw/issues/100173),
  [#101250](https://github.com/openclaw/openclaw/issues/101250) — bug
  upstream "reply session initialization conflicted".

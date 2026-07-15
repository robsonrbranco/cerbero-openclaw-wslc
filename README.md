# Cerbero — OpenClaw no WSLC (WSL Containers): Claude + DeepSeek + Gemini + WhatsApp

> Na mitologia grega, **Cérbero** é o cão de três cabeças que guarda os
> portões do submundo — controla estritamente quem entra e quem sai, sem
> exceção. É a mesma função deste container: um gateway que autentica e
> filtra cada mensagem antes de deixá-la passar, com três "cabeças" — os
> três provedores de modelo (Claude, DeepSeek, Gemini) — vigiando a mesma
> porta de entrada.

Este pacote sobe o [OpenClaw](https://openclaw.ai) num único container Linux
usando o **WSL Containers** da Microsoft (`wslc.exe`), em preview público desde
30/06/2026 (GA prevista para o outono de 2026), com os provedores de modelo
Anthropic (Claude), DeepSeek e Google (Gemini) e o canal WhatsApp.

O container roda com o usuário Linux `cerbero` (não-root, uid/gid 1000 —
mesmo uid do usuário `node` da imagem oficial, só renomeado), em homenagem ao
nome do próprio agente/projeto: **Cerbero**.

Se algo quebrar (erro de permissão, quoting do PowerShell, plugin que não
reinstala, modelo que não aparece no select), veja primeiro
**[LICOES-APRENDIDAS.md](./LICOES-APRENDIDAS.md)** — é o registro de todas as
causas-raiz e soluções já descobertas nesta instalação, pra não reinvestigar
do zero.

## Convenções deste projeto

Duas regras valem para todo este pacote (scripts, config, README):

1. **Vocabulário — "wslc", não "docker", para a nossa própria infraestrutura.**
   Esta máquina pode ter Docker de verdade instalado ao lado do WSLC. Para não
   confundir qual runtime está rodando o quê, usamos "wslc"/"container" para
   descrever nossas próprias ações e artefatos (builda-se "no wslc", "o
   container do gateway", etc.), e reservamos a palavra "docker"/"Docker"
   apenas para referências factuais a coisas que realmente se chamam assim: o
   `docker-compose.yml` oficial do OpenClaw, o Docker Engine, o Docker Hub, ou
   o formato de build `Dockerfile` (que o `wslc build` também entende).
2. **Nome do projeto fixo em tudo que for possível: `cerbero`.** Como o mesmo
   host pode ter vários containers WSLC rodando ao mesmo tempo (deste projeto
   ou de outros), todo identificador que criamos usa o prefixo/nome `cerbero`
   em vez de um nome genérico: tag de imagem (`cerbero:local`), nome do
   container (`cerbero-gateway`), pasta de dados persistentes
   (`C:\wslc\data\cerbero`) e os próprios scripts (`cerbero-cli.ps1`,
   `setup-cerbero-wslc.ps1`, `cerbero.json5`). Isso evita colisão de nomes e
   deixa claro, num `wslc container ps` com vários containers, qual é qual.

## Layout do projeto (agnóstico de ferramenta)

Este pacote foi originalmente construído dentro da pasta que você conectou ao
Cowork (`...\workspace\wslc\cerbero-wslc\`). Isso amarra a localização do
projeto a essa ferramenta/sessão específica, o que não é ideal para algo que
você vai manter rodando por conta própria. O layout recomendado — e para onde
os defaults deste pacote já apontam — separa fonte e dados numa raiz própria,
fora de qualquer pasta de app:

```
C:\wslc\
├── projects\cerbero\   <- código-fonte (este pacote); pode virar um repo git
└── data\cerbero\       <- dados persistentes (config/workspace/secrets/logs/.env)
```

**Se você ainda está na pasta conectada ao Cowork**, rode uma vez o script de
migração que está na raiz dela (um nível acima desta pasta):

```powershell
cd ..
.\migrate-cerbero-to-agnostic-layout.ps1
```

Ele move `cerbero-wslc\` para `C:\wslc\projects\cerbero\`, migra os dados de
`$HOME\cerbero-wslc-data\` (se existirem) para `C:\wslc\data\cerbero\`
preservando o vínculo do WhatsApp e as chaves já configuradas, **copia** (sem
apagar a origem) os `.md` de personalidade/memória de uma instalação nativa do
OpenClaw em `$HOME\.openclaw\workspace\` para dentro do novo
`workspace\` do container, arquiva qualquer protótipo solto que você tenha
feito por fora desta conversa em `C:\wslc\_archive\`, e recria o container
`cerbero-gateway` já apontando pro novo lugar. Use `-SkipPersonality` se não
quiser essa cópia. Depois disso, trabalhe direto em `C:\wslc\projects\cerbero\`
— a pasta conectada ao Cowork vira só o histórico desta conversa.

**Se você está começando do zero** (sem nunca ter rodado o setup), pode
simplesmente copiar este pacote direto para `C:\wslc\projects\cerbero\` e
seguir o resto deste README a partir de lá; os scripts já usam
`C:\wslc\data\cerbero` como `BaseDir` padrão.

## 0. Antes de tudo: por que não Docker Compose

O fluxo oficial de container do OpenClaw (`docs.openclaw.ai/install/docker`) é
baseado em `docker-compose.yml`, com dois serviços (`openclaw-gateway` e
`openclaw-cli` compartilhando namespace de rede — nomes da documentação
oficial do OpenClaw, não deste pacote). O `wslc.exe`, no estado atual do
preview, documenta bem operações de container único — `run`, `build`,
`image ls`, `container ps/stop` — mas **não lista suporte a `docker compose`**
como capacidade confirmada (release notes 2.9.3 do WSL não mencionam Compose
como item de destaque).

Por isso este pacote usa **um único container "all-in-one"**, montando na mão
os mesmos volumes/porta que o compose oficial define, em vez de depender de
`docker compose up`. É a forma mais alinhada ao que o WSLC hoje comprovadamente
suporta.

### Limitações conhecidas do preview (validar antes de depender em produção)

- **Rede (consomme)**: não relaia multicast/broadcast (mDNS/Bonjour/SSDP/UPnP),
  não repassa erros ICMP, traceroute é parcial, e protocolos GRE/ESP/SCTP são
  descartados. Por isso o config já vem com `OPENCLAW_DISABLE_BONJOUR=1`.
- **`docker compose`**: sem suporte confirmado — daí a arquitetura single-container.
- Ainda é **preview**: teste antes de tratar como produção crítica.

Atualização: na prática, instalar plugins (WhatsApp) e configurar modelos
funciona melhor rodando os próprios comandos `openclaw ...` (via um container
avulso que só compartilha os volumes de config/segredos, sem precisar de
`--network container:` nem `exec` no container do gateway). Isso porque
`plugins install`, `channels login` (QR) e `models auth login` só leem/escrevem
arquivos em `~/.openclaw` — não precisam falar com o processo do gateway em
execução. Veja a seção **Plugins e canais via CLI** abaixo.

Se preferir não lidar com essas arestas agora, a alternativa é rodar o fluxo
oficial via Docker Engine dentro do WSL2 (não WSLC) com `docker compose` —
posso preparar esse caminho também, é só pedir.

## 1. Pré-requisitos

```powershell
wsl --update --pre-release
wslc version
```

Se `wslc version` não responder, o preview não está ativo na sua máquina —
pare aqui e atualize o WSL primeiro.

`gh` (GitHub CLI) confirmado instalado neste host — foi usado para publicar
este repositório e do projeto irmão Hermes; útil para qualquer fluxo futuro
de PR/release destes projetos.

## 2. Arquivos deste pacote

| Arquivo            | Papel                                                        |
| ------------------- | ------------------------------------------------------------- |
| `Dockerfile`         | Camada fina sobre a imagem oficial `ghcr.io/openclaw/openclaw:latest`, usuário renomeado pra `cerbero`, + ffmpeg |
| `cerbero.json5`     | **Legado/histórico** — não é mais usado pelo setup (a config nasce 100% via `openclaw onboard`/`config set`, ver seção 4) |
| `.env.example`       | Template das API keys e do token do gateway                  |
| `setup-cerbero-wslc.ps1`     | Build + volumes nomeados + bootstrap completo via CLI (auth, modelos, WhatsApp, plugins) + sobe o gateway — idempotente, roda de novo sem medo |
| `cerbero-cli.ps1`   | Roda qualquer comando `openclaw ...` avulso (ex.: `channels login` para o QR do WhatsApp) reusando os mesmos volumes |

### Pastas persistentes (volumes do `cerbero-gateway`)

Tudo abaixo vive em `C:\wslc\data\cerbero\` (BaseDir padrão) e
sobrevive a `wslc container rm`/rebuild de imagem — só some se você apagar a
pasta manualmente:

| Pasta no host | Caminho no container | O que guarda |
| --- | --- | --- |
| `config`    | `/home/cerbero/.openclaw`        | `openclaw.json`, sessões |
| `workspace` | `/home/cerbero/.openclaw/workspace` | Workspace de arquivos do agente |
| `secrets`   | `/home/cerbero/.config/openclaw` | Chave de criptografia dos auth-profiles |
| `logs`      | `/tmp/openclaw`                  | Logs rolantes do OpenClaw — por padrão `/tmp` não persiste entre recriações do container; mapeamos essa pasta específica para reter histórico útil em debug futuro |

Além dessas pastas do Windows, existem 4 **volumes nomeados** (vivem dentro da
VM do WSLC, não aparecem no Explorer, mas persistem entre recriações do
container tanto quanto as pastas acima):

| Volume nomeado | Caminho no container | Por que não é bind mount do Windows |
| --- | --- | --- |
| `cerbero-npm` | `/home/cerbero/.openclaw/npm` | Plugins instalados via npm — virtiofs reporta bind mounts como `mode=777`, e o OpenClaw bloqueia plugins carregados de caminho world-writable |
| `cerbero-agents` | `/home/cerbero/.openclaw/agents` | Auth-profile-store (sqlite) — bind mount do Windows não segura `flock`/`fcntl` direito |
| `cerbero-extensions` | `/home/cerbero/.openclaw/extensions` | Plugins instalados via ClawHub (ex.: WhatsApp) — mesmo motivo do `cerbero-npm` |
| `cerbero-state` | `/home/cerbero/.openclaw/state` | State principal (sqlite) — mesmo motivo do `cerbero-agents` |

`C:\wslc\data\cerbero\.env` fica ao lado dessas pastas mas **não**
é um volume montado — é só lido pelos scripts a cada execução e injetado como
variável de ambiente do processo (`-e`), então não aparece como arquivo dentro
do container.

## 3. Preencher os segredos

1. Rode `.\setup-cerbero-wslc.ps1` uma primeira vez — ele cria `C:\wslc\data\cerbero\.env`
   a partir do `.env.example` e para aí.
2. Abra esse `.env` e preencha:
   - `ANTHROPIC_API_KEY` — [console.anthropic.com](https://console.anthropic.com/)
   - `DEEPSEEK_API_KEY` — [platform.deepseek.com/api_keys](https://platform.deepseek.com/api_keys)
   - `GEMINI_API_KEY` — Google AI Studio
   - `OPENCLAW_GATEWAY_TOKEN` — qualquer string aleatória forte (ex.: `openssl rand -hex 32`,
     ou no PowerShell: `[System.Convert]::ToBase64String((1..32|%{Get-Random -Max 256}))`)

Não precisa mais editar nenhum JSON à mão — o número de WhatsApp tem default
próprio no script (`-WhatsappNumber`, já vem com o número pessoal configurado);
troque só se for outro número:

```powershell
.\setup-cerbero-wslc.ps1 -WhatsappNumber "+5511999998888"
```

## 4. Subir o gateway (build + bootstrap completo)

```powershell
.\setup-cerbero-wslc.ps1
```

O script faz tudo em sequência, de forma idempotente (pode rodar de novo a
qualquer momento sem quebrar o que já está configurado):

- builda a imagem (`wslc build`), com a tag `cerbero:local`
- cria (se não existirem) os volumes nomeados `cerbero-npm`/`cerbero-agents`/`cerbero-extensions`/`cerbero-state`
  e corrige a permissão deles (ver seção "Pastas persistentes" abaixo)
- autentica os 3 provedores via `openclaw onboard --non-interactive` (Anthropic, DeepSeek, Google) —
  isso já cria o `openclaw.json` e instala os plugins de provider
- define prioridade de modelo (`models set`/`models fallbacks`): DeepSeek V4 Flash → Gemini 3.5 Flash → Claude Haiku 4.5
- define aliases/allowlist de modelos, `gateway.bind`, origens do Control UI, desliga o Bonjour
- configura o canal WhatsApp (`allowFrom`, `selfChatMode`, etc.) e instala o plugin via ClawHub
- libera `plugins.allow` para os plugins usados
- cria/recria o container `cerbero-gateway` com as portas e volumes corretos
- confere `/healthz`

Único passo que continua manual — só precisa ser feito uma vez, fica salvo no
volume `cerbero-agents`:

```powershell
.\cerbero-cli.ps1 channels login --channel whatsapp
```

Isso mostra um QR no terminal; escaneie com o WhatsApp do celular (Aparelhos
conectados → Conectar aparelho).

Ao final, abra `http://127.0.0.1:18789/` e cole o `OPENCLAW_GATEWAY_TOKEN` do
`.env` na tela de Settings para acessar a Control UI.

Comandos úteis de operação:

```powershell
wslc container ps                       # status
wslc container logs -f cerbero-gateway  # logs
wslc container stop cerbero-gateway
wslc container start cerbero-gateway
```

## 5. Plugins e canais via CLI (o que ainda é manual, e comandos úteis)

O `setup-cerbero-wslc.ps1` já autentica os 3 provedores, define modelos/allowlist,
configura o canal WhatsApp e instala o plugin via ClawHub — tudo isso acontece
num container descartável que só compartilha os volumes de config/segredos com
o gateway (`plugins install`, `models auth login` etc. só leem/escrevem
arquivos em `~/.openclaw`, não precisam falar com o processo do gateway em
execução). `cerbero-cli.ps1` expõe esse mesmo caminho pra rodar qualquer
comando avulso.

O único passo que continua manual — vincular o QR do WhatsApp — só precisa
ser feito uma vez (o vínculo fica salvo no volume `cerbero-agents`, sobrevive
a rebuild):

```powershell
.\cerbero-cli.ps1 channels login --channel whatsapp
```

Depois de vincular, se o gateway já estava rodando, reinicie pra ele enxergar
o vínculo nesta sessão:

```powershell
wslc container stop cerbero-gateway
wslc container start cerbero-gateway
# (esta preview do wslc nao tem um subcomando "restart" unico - so stop/start)
```

Outros comandos úteis pelo mesmo caminho (leem só arquivo, não precisam do
gateway rodando):

```powershell
.\cerbero-cli.ps1 models list --provider anthropic
.\cerbero-cli.ps1 models list --provider deepseek
.\cerbero-cli.ps1 models list --provider google
.\cerbero-cli.ps1 models status
.\cerbero-cli.ps1 doctor
```

**Limite importante do `cerbero-cli.ps1`**: ele sobe um container *descartável*
a cada chamada, que **não compartilha o namespace de rede** do
`cerbero-gateway` já em execução. Comandos que precisam falar com o processo
do gateway ao vivo — `channels status`, `gateway status`, `dashboard` — falham
por aqui com algo como `Gateway not reachable: gateway closed (1006 abnormal
closure)`. Pra esses, rode dentro do próprio container do gateway:

```powershell
wslc container exec cerbero-gateway openclaw channels status
wslc container exec cerbero-gateway openclaw gateway status
```

ou use a Control UI web (`http://127.0.0.1:18789/`).

Depois de vincular, seu WhatsApp pessoal já está liberado (`allowFrom` +
`selfChatMode: true`, configurados pelo próprio `setup-cerbero-wslc.ps1`) e as
mensagens passam a usar o modelo principal configurado
(`agents.defaults.model.primary`), com fallback automático pela ordem de
`agents.defaults.model.fallbacks` se o principal estiver
indisponível/limitado. Confira a ordem atual com
`.\cerbero-cli.ps1 models status`.

## 5b. Nome do serviço (`-Hostname`) e acesso pelo nome no navegador

Este projeto é autossuficiente: tudo que ele precisa (build, volumes, rede,
resolução de nome) está nos próprios scripts, sem depender de nenhum outro
projeto WSLC no host.

O container é endereçado pelo parâmetro `-Hostname` (default
`cerbero-gateway`, igual a `-ContainerName`). Esse valor é usado em três
lugares consistentemente: como alias na rede compartilhada (se
`-SharedNetwork` estiver ativo), nas origens permitidas do Control UI
(`gateway.controlUi.allowedOrigins`), e como a entrada que
`scripts/add-hosts-entries.ps1` cria no arquivo hosts do Windows. Trocar só
esse parâmetro (ex.: `-Hostname cerbero.suaempresa.com` numa futura migração
para nuvem) atualiza os três lugares de uma vez, sem precisar caçar
`"cerbero-gateway"`/`"localhost"` hardcoded em vários arquivos.

Para acessar `http://cerbero-gateway:18789` direto do navegador do Windows
(além de `http://127.0.0.1:18789`, que sempre funciona), rode uma vez como
Administrador:

```powershell
.\scripts\add-hosts-entries.ps1
```

Ele mapeia `cerbero-gateway` para `127.0.0.1` no arquivo hosts do Windows
(com backup automático e idempotência — ver o cabeçalho do script para
detalhes).

### Comunicação com outros containers WSLC no mesmo host (opcional)

Se este host também rodar outro container WSLC com quem o Cerbero precise
falar diretamente (por exemplo, o projeto irmão [Hermes](../hermes)/n8n,
acionando o gateway a partir de um workflow), o parâmetro `-SharedNetwork`
(default `hermes-cerbero-net`) conecta o Cerbero numa rede nomeada do WSLC
compartilhada — mas isso é opcional e só faz sentido se o outro projeto
também estiver configurado para usar a mesma rede. Nenhum dos dois projetos
depende do outro para funcionar sozinho. Detalhes técnicos (por que isso é
necessário, como funciona) em `LICOES-APRENDIDAS.md`, seção 16.

## 6. Verificação final

- [ ] `wslc container ps` mostra `cerbero-gateway` como `Up`
- [ ] `http://127.0.0.1:18789/healthz` responde 200
- [ ] Control UI abre e aceita o token
- [ ] `.\cerbero-cli.ps1 models list --provider anthropic|deepseek|google` lista modelos sem erro de auth
- [ ] `wslc container exec cerbero-gateway openclaw channels status` mostra o WhatsApp vinculado
- [ ] Mensagem de teste no seu WhatsApp responde

## 7. Trocar modelo primário / ajustar fallback

Via CLI, não editando `openclaw.json` na mão (mesma lógica do resto deste
pacote — ver seção 0):

```powershell
.\cerbero-cli.ps1 models set <provider>/<modelo>
.\cerbero-cli.ps1 models fallbacks clear
.\cerbero-cli.ps1 models fallbacks add <provider>/<modelo-fallback-1>
.\cerbero-cli.ps1 models fallbacks add <provider>/<modelo-fallback-2>
```

Depois reinicie o gateway:

```powershell
wslc container stop cerbero-gateway
wslc container start cerbero-gateway
# (esta preview do wslc nao tem um subcomando "restart" unico - so stop/start)
```

Confirme os refs exatos de modelo disponíveis com
`.\cerbero-cli.ps1 models list --all --provider <nome>` antes de trocar — o
catálogo muda entre versões. A prioridade atual é sempre visível com
`.\cerbero-cli.ps1 models status`.

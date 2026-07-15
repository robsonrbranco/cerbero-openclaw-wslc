# Infraestrutura WSLC — Hermes, Cerbero, Argos

> Documento gerado em 15/07/2026 para o próprio Cerbero (OpenClaw) ler e
> incorporar à sua memória de longo prazo (`MEMORY.md`). Resume tudo que foi
> orquestrado nesta sessão de trabalho com o Claude sobre a infraestrutura de
> containers WSLC deste host. Corrige informações desatualizadas que já
> estavam registradas na memória do Cerbero (ver seção "Correções" no final).

## 1. Visão geral

Três containers WSLC (`wslc.exe`, WSL Containers da Microsoft, preview
público desde 30/06/2026), cada um em um projeto **independente e
autossuficiente** — nenhum depende dos scripts/arquivos dos outros, cada um
resolve sozinho suas próprias necessidades de infraestrutura (build,
volumes, rede, resolução de nome). Comunicação entre eles acontece só por
HTTP, na mesma rede nomeada do WSLC.

Nome mitológico de cada um, escolhido pelo papel que exerce (não é só
estética — cada README explica a analogia):

| Projeto | Papel | Nome mitológico |
|---|---|---|
| **Hermes** | Orquestração de workflows (n8n) | Mensageiro dos deuses — conecta serviços, dispara mensagens/webhooks |
| **Cerbero** | Gateway de IA (OpenClaw: Claude + DeepSeek + Gemini + WhatsApp) | Cão de três cabeças que guarda o portão — uma cabeça por provedor de modelo |
| **Argos** | Scraper/automação com certificado digital (Playwright) | Gigante de cem olhos, sempre vigiando — navega e extrai dados de páginas autenticadas |

## 2. Rede compartilhada e nomes (`-Hostname`)

Todos os três usam a mesma rede nomeada do WSLC: **`hermes-cerbero-net`**
(parâmetro `-SharedNetwork` em cada `setup-*-wslc.ps1`, default idêntico
nos três). Containers na mesma rede nomeada se resolvem por **nome**, na
**porta interna** (não a porta publicada no host com `-p`):

| Container | Hostname interno | Porta interna | Porta publicada no host |
|---|---|---|---|
| Hermes (n8n) | `hermes-n8n` | 5678 | 5678 |
| Cerbero (gateway) | `cerbero-gateway` | 18789 | 18789 |
| Argos (scraper) | `argos-scraper` | 5679 | 5679 |

Cada projeto tem seu próprio `-Hostname` (parâmetro separado de
`-ContainerName`, pensando em migração futura pra um domínio real na
nuvem) e seu próprio `scripts/add-hosts-entries.ps1`, que mapeia o hostname
para `127.0.0.1` no `C:\Windows\System32\drivers\etc\hosts` — necessário
porque a rede nomeada do WSLC só dá resolução de nome **entre containers**,
não do host Windows para dentro deles.

**Chamada real em uso**: um workflow no Hermes (n8n) aciona o Argos via
HTTP Request node em `http://argos-scraper:5679/scrape` para consultas no
CAV (Centro de Atendimento Virtual) da Receita Federal, autenticadas via
certificado digital A1 + Acesso GovBR.

## 3. Hermes (n8n)

- **Imagem**: oficial, `ghcr.io/n8n-io/n8n:latest` — **sem modificações de
  sistema**. A base (`n8nio/base`) não tem gerenciador de pacote nenhum
  (nem `apk` nem `apt-get`), então nada de Python/Playwright/certificado
  pode viver aqui — só o n8n puro.
- **Dados**: volume nomeado `hermes-data` → `/home/node/.n8n` (banco
  SQLite, credenciais criptografadas, workflows).
- **Segredos**: `C:\wslc\data\hermes\.env` — `N8N_ENCRYPTION_KEY` (nunca
  trocar depois de existirem credenciais salvas), `N8N_HOST`/
  `N8N_WEBHOOK_URL` apontando para `hermes-n8n` (não `localhost`).
- **CMD do Dockerfile**: `CMD ["start"]` — só o subcomando, porque o
  `docker-entrypoint.sh` oficial já prefixa `n8n` sozinho (`CMD ["n8n",
  "start"]` duplicaria o binário e falhava com `Command "n8n" not found`).

## 4. Cerbero (OpenClaw)

Sem mudanças de arquitetura nesta sessão — ver o próprio
`LICOES-APRENDIDAS.md` deste projeto para o histórico completo. Único
ajuste feito agora: `-Hostname cerbero-gateway` também na lista de
`allowedOrigins` do Control UI (`cerbero.json5` e mensagem final do
`setup-cerbero-wslc.ps1`), em vez de só `localhost`/`127.0.0.1`.

## 5. Argos (scraper Playwright + certificado A1) — projeto novo

Criado nesta sessão para resolver um problema real: um workflow do Hermes
precisava de Python + Playwright + Chromium + certificado digital A1 para
autenticar via GovBR e consultar o CAV da Receita Federal, mas a imagem
oficial do n8n não permite instalar nada disso (sem gerenciador de
pacote). Em vez de reconstruir o n8n inteiro sobre Debian (opção
descartada — perderia updates automáticos da imagem oficial), criamos um
projeto irmão dedicado:

- **Imagem**: `FROM debian:bookworm-slim`, com Python3 + Playwright +
  Chromium + `certutil`/`pk12util` (NSS) instalados livremente.
- **Serviço**: `scraper-server.py` expõe HTTP `/scrape` (POST) e `/health`
  (GET) na porta 5679 — é isso que o Hermes chama.
- **Certificado**: `certs/certificado-A1.pfx` + `certs/CNPJ.pdf` — **só
  existem no Argos agora**, não mais no Hermes nem no Cerbero. Certificado
  real da empresa do usuário, usado para prototipagem dos workflows
  (não produção).
- **Segredo**: senha do certificado em `CERT_PASSWORD`, no
  `C:\wslc\data\argos\.env` — **nunca hardcoded em código** (isso foi um
  achado de segurança corrigido nesta sessão, ver seção 7).
- **Volume nomeado**: `argos-cache` → `/home/argos/.cache` (cache de
  browsers do Playwright, evita rebaixar o Chromium a cada rebuild).
- **Git**: projeto criado com `.gitignore` já protegendo `certs/` desde o
  primeiro commit (diferente do Hermes, que teve a pasta desprotegida por
  um tempo antes de ser corrigido).

## 6. Layout de pastas (padrão nos três projetos)

```
C:\wslc\
├── projects\hermes\   <- código-fonte (git)
├── projects\cerbero\  <- código-fonte (git)
├── projects\argos\    <- código-fonte (git, local por enquanto)
├── data\hermes\        <- só .env (dados reais no volume "hermes-data")
├── data\cerbero\       <- config/workspace/secrets/logs (ver MEMORY.md)
└── data\argos\         <- só .env (dados reais no volume "argos-cache")
```

## 7. Achado de segurança corrigido nesta sessão

Os scripts Python do scraper (`cav-scraper.py`, `scraper-server.py`)
tinham a senha do certificado A1 **hardcoded** como valor default
(`DEFAULT_PASS = "LQpkUqb6JB5VU"`). Como ainda não tinham sido commitados,
foi possível corrigir sem deixar rastro no histórico git: os dois agora
leem exclusivamente de `os.environ.get("CERT_PASSWORD", "")`.

**Atenção**: a mesma senha em texto puro está registrada hoje na seção
"📜 Certificado A1" do `MEMORY.md` deste projeto (linha com `**Senha:**
LQpkUqb6JB5VU`). Recomenda-se substituir essa linha por uma referência ao
arquivo (`ver CERT_PASSWORD em C:\wslc\data\argos\.env`), sem repetir o
valor real em texto puro num arquivo de memória.

## 8. Bug de infraestrutura descoberto nesta sessão (relevante para qualquer edição futura de arquivo neste host)

Ao editar arquivos em `C:\wslc\projects\*` por fora do Windows (via
ferramentas rodando num sandbox Linux/mount virtiofs-like), escritas
grandes ocasionalmente ficam **truncadas silenciosamente** — a operação
reporta sucesso, mas o arquivo no disco fica cortado no meio do conteúdo
novo (chegou a acontecer com `Dockerfile`, `README.md` e
`LICOES-APRENDIDAS.md` do Hermes, inclusive já commitado). Não é um bug do
`wslc.exe` nem do WSLC em si — é do mecanismo de montagem usado por
ferramentas externas para acessar esses arquivos. Mitigação aplicada:
sempre reconferir o arquivo inteiro (tamanho em bytes e conteúdo do final
do arquivo) logo após qualquer escrita grande, antes de considerar a
mudança concluída.

## 9. Estado do git em cada projeto (15/07/2026)

- **Hermes**: commitado e verificado (`git log` tem os commits da
  reversão pra imagem oficial, separação do Argos, troca pra hostname, e
  a introdução mitológica no README).
- **Cerbero**: mudanças de hostname (`cerbero.json5`,
  `setup-cerbero-wslc.ps1`) e a introdução mitológica no README ainda
  **não commitadas** — pendente de `git add` + `git commit` manual.
- **Argos**: projeto completo, mas **ainda sem `git init`** — pendente de
  inicialização manual (`git init -b master` + `git add -A` + primeiro
  commit). Mantido **local por enquanto**, sem publicar no GitHub (decisão
  explícita do usuário, por conter um certificado digital real da
  empresa).

## Correções a aplicar no `MEMORY.md` do Cerbero

Comparando com o estado real da infraestrutura hoje, os seguintes trechos
do `MEMORY.md` atual estão desatualizados:

1. **Seção "🐳 Padronização de Distribuição"**: diz que "Hermes (n8n):
   Migrado para Debian Bookworm via Dockerfile próprio" — **não é mais
   verdade**. O Hermes voltou à imagem oficial `ghcr.io/n8n-io/n8n:latest`
   (sem modificação de sistema). O container Debian+Python+Playwright
   virou o projeto separado **Argos**.
2. **Seção "🔗 n8n — Hermes"**: diz "Scraper HTTP Server:
   `http://hermes-n8n:5679`" — **mudou** para `http://argos-scraper:5679`
   (container próprio, não mais dentro do Hermes).
3. **Seção "📜 Certificado A1"**: diz que o certificado está "em ambos
   projetos: `cerbero/` e `hermes/`" — **mudou**: vive só em
   `argos/certs/`. E a senha em texto puro deveria ser removida da memória
   (ver seção 7 acima).
4. **Falta o projeto Argos inteiro** — não existia quando o `MEMORY.md`
   foi escrito pela última vez.

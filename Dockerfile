# Cerbero - OpenClaw para WSL Containers (wslc.exe)
# -----------------------------------------------------------------------------
# Em vez de recompilar o OpenClaw a partir do source (que exige pnpm/tsdown e >=2GB
# de RAM so pro build), partimos da imagem oficial ja publicada no GHCR/Docker Hub.
# Isso reduz este arquivo de build a uma camada fina, o que importa no WSLC hoje: e
# preview, entao quanto menos "magica" de build, menor a chance de esbarrar numa
# limitacao ainda nao madura do runtime.
#
# Tags oficiais: main, latest, <versao> (ex.: 2026.2.26). O tag "latest" ja vem com
# os plugins codex e diagnostics-otel. Existe tambem uma variante "-browser" com
# Chromium, que nao usamos aqui pois nao foi pedida.
#
# Nota de vocabulario: o nome "Dockerfile" e so o formato de build que o
# `wslc build` tambem entende - o runtime alvo deste projeto e o WSLC, nao o
# Docker. No restante deste pacote (scripts, README) evitamos a palavra
# "docker" para descrever nossa propria infraestrutura, porque esta maquina
# pode ter Docker de verdade rodando ao lado, e "wslc"/"container" deixa claro
# qual runtime esta em jogo.
#
# Nao usamos a diretiva "# syntax=docker/dockerfile:1" de proposito: ela faz o
# builder buscar o frontend na Docker Hub antes mesmo de comecar o build, o
# que falha se a rede do WSLC nao alcancar registry-1.docker.io nesse momento.
# Este Dockerfile so usa instrucoes basicas (FROM/USER/RUN/ENV/WORKDIR/EXPOSE/
# CMD), que o frontend padrao ja resolve sem precisar buscar nada.

# Versao pinada de proposito (09/09/2026, atualizando de 2026.9.1 pra
# 2026.9.3, dois patches) -- "latest" foi exatamente como a imagem ficou 2
# meses desatualizada sem ninguem perceber da ultima vez (ver
# LICOES-APRENDIDAS.md, feedback_openclaw_version_skew na memoria do
# Claude Code). Pra atualizar de novo no futuro, trocar o numero aqui
# deliberadamente, nao voltar pra "latest".
FROM ghcr.io/openclaw/openclaw:2026.9.3

USER root

# ffmpeg e usado pelo canal WhatsApp para transcodificar audio (TTS / voice notes)
# para Ogg/Opus 48kHz quando o formato de origem nao e nativo. git/curl/jq ajudam
# em diagnostico dentro do container. sudo entra por causa do "openclaw update":
# sem ele, dava "Update skipped: not-git-install. Not a git checkout." porque a
# imagem oficial instala o OpenClaw globalmente (nao via git clone), e a
# reinstalacao global exige escrever em pasta do npm que so o root pode tocar -
# sem sudo nao tem como o usuario "cerbero" (nao-root) rodar essa atualizacao.
# Mantemos a lista curta de proposito.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg git curl jq sudo \
    && rm -rf /var/lib/apt/lists/*

# -----------------------------------------------------------------------------
# gog (Google Workspace CLI, github.com/openclaw/gogcli) - usado pro scan de
# e-mail/agenda nos crons de briefing/wrap-up. Na era WSLC isso era instalado
# em runtime via bootstrap-gog.sh (chamado pelo setup-cerbero-wslc.ps1) porque
# o volume que guardava o binario baixado podia sumir entre rebuilds do
# ambiente local. Migrado pro k3s, o binario passa a vir DENTRO da imagem
# (mesma logica do plugin WhatsApp abaixo: falha cedo e visivelmente no build
# em vez de depender de download em runtime). Versao pinada de proposito -
# nunca "latest" (ver historico de dor com ghcr.io/openclaw/openclaw:latest
# ficando desalinhado do resto do sistema). Pra atualizar, trocar o numero da
# versao e a URL do release em https://github.com/openclaw/gogcli/releases.
RUN curl -sL "https://github.com/openclaw/gogcli/releases/download/v0.34.1/gogcli_0.34.1_linux_amd64.tar.gz" \
    | tar xz -C /tmp/ \
    && mv /tmp/gog /usr/local/bin/gog \
    && chmod +x /usr/local/bin/gog

# -----------------------------------------------------------------------------
# wacli (WhatsApp CLI, github.com/openclaw/wacli) - segundo dispositivo
# vinculado, usado SOMENTE para indexar e consultar o grupo de condicoes de voo
# de Sampaio. Versao e SHA-256 ficam fixos para o build ser reproduzivel e nao
# executar um artefato trocado no upstream. A sessao nao vive na imagem: o
# manifest aponta WACLI_STORE_DIR para o PVC persistente cerbero-data.
ARG WACLI_VERSION=0.16.0
ARG WACLI_SHA256=65087d5fb398e5a20d21162e60f3ac56aed3dea36610bc5cec57f03d58344680
# Extraimos num subdiretorio proprio (nao direto em /tmp): o tarball do wacli
# empacota uma entrada de diretorio "." com dono/permissao de build (uid 501,
# tipico de macOS) que o tar aplica ao proprio diretorio de destino - extrair
# direto em /tmp deixava /tmp inteiro sem escrita pro usuario nao-root
# "cerbero", derrubando o gateway com EACCES em qualquer mkdir de /tmp
# (descoberto em produção em 11/08/2026). /tmp/wacli-extract e descartavel e
# removido no fim do RUN, entao nao herda esse problema para o resto da imagem.
RUN mkdir -p /tmp/wacli-extract \
    && curl -fsSL -o /tmp/wacli.tar.gz \
      "https://github.com/openclaw/wacli/releases/download/v${WACLI_VERSION}/wacli_${WACLI_VERSION}_linux_amd64.tar.gz" \
    && echo "${WACLI_SHA256}  /tmp/wacli.tar.gz" | sha256sum -c - \
    && tar -xzf /tmp/wacli.tar.gz -C /tmp/wacli-extract \
    && install -m 0755 /tmp/wacli-extract/wacli /usr/local/bin/wacli \
    && rm -rf /tmp/wacli.tar.gz /tmp/wacli-extract \
    && chmod 1777 /tmp

# -----------------------------------------------------------------------------
# Claude Code CLI - instalado direto na imagem pra aparecer como "CLI nativa"
# disponivel no OpenClaw (o plugin Anthropic ja embutido detecta um binario
# "claude" no PATH e o expoe como native session catalog - nao precisa
# habilitar nenhum plugin extra pra isso). E uma instancia generica do
# Gateway, sem conta/config pessoal vinculada (diferente de parear uma
# maquina real como "node" via `openclaw connect`, que usaria a conta do
# usuario) - decisao consciente de 09/09/2026, mais simples de manter.
# Versao pinada de proposito (mesma logica do gogcli/wacli acima - nunca
# "latest"). Pra atualizar, checar `npm view @anthropic-ai/claude-code
# version` e trocar o numero aqui deliberadamente.
#
# O "npm install -g" sozinho nao e suficiente: o pacote baixa o binario
# nativo de verdade num postinstall separado (dependencia opcional
# platform-specific), e esse passo falhou silenciosamente aqui mesmo
# rodando como root (motivo exato nao confirmado - suspeita de timing/
# rede no ambiente do build) - o binario ficava um stub que so imprime
# "claude native binary not installed" (descoberto em producao em
# 09/09/2026). Por isso rodamos o install.cjs de novo explicitamente e
# validamos com `claude --version` no proprio build - se isso voltar a
# falhar, o build inteiro para (fail cedo, mesma logica do plugin
# WhatsApp mais abaixo), em vez de descobrir isso so quando alguem tenta
# usar a CLI pelo dashboard do OpenClaw.
RUN npm install -g @anthropic-ai/claude-code@2.1.266 \
    && node /usr/local/lib/node_modules/@anthropic-ai/claude-code/install.cjs \
    && claude --version

# -----------------------------------------------------------------------------
# zoho-mail - CLI caseiro pra API do Zoho Mail (contato@ecomciencia.com),
# fonte em scripts/zoho-mail.sh. Nao existe um CLI oficial tipo o gogcli
# pro Zoho, entao escrevemos um wrapper fino em cima de curl+jq (ja
# instalados acima) - sem dependencia nova. Credenciais (client id/
# secret/refresh token/account id) vem 100% de env vars (Secret
# cerbero-env), nunca hardcoded. Renova o access token a cada chamada
# (expira em 1h) via refresh_token - simples e robusto, sem cache pra
# estragar. Endpoints conferidos na documentacao oficial (mail.zoho.com/
# api, nao www.zohoapis.com - sao dominios diferentes mesmo pra mesma
# conta) em 24/07/2026, ver https://www.zoho.com/mail/help/api/.
COPY scripts/zoho-mail.sh /usr/local/bin/zoho-mail
COPY scripts/wacli-sampaio.sh /usr/local/bin/wacli-sampaio
COPY scripts/wacli-base.sh /usr/local/bin/wacli-base
RUN chmod +x /usr/local/bin/zoho-mail /usr/local/bin/wacli-sampaio /usr/local/bin/wacli-base

# -----------------------------------------------------------------------------
# Renomeia o usuario nao-root da imagem oficial (node, uid/gid 1000) para
# "cerbero" - o nome do projeto/agente. Mantemos o mesmo uid/gid 1000 de
# proposito: e o que os bind mounts do host devem ter (chown -R 1000:1000 ...),
# so muda o nome/HOME exibido dentro do container.
# -----------------------------------------------------------------------------
RUN groupmod -n cerbero node \
    && usermod -l cerbero -d /home/cerbero -m -c "Cerbero (OpenClaw agent user)" node \
    && mkdir -p /home/cerbero/.openclaw /home/cerbero/.config/openclaw /tmp/openclaw \
    && chown -R cerbero:cerbero /home/cerbero /tmp/openclaw

# Sudo sem senha pro cerbero - sem TTY interativo no container nao ha como
# digitar senha; usado pelo "openclaw update" (reinstalacao global exige root)
# e disponivel tambem pra qualquer diagnostico manual (wslc container exec).
RUN echo "cerbero ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/cerbero \
    && chmod 0440 /etc/sudoers.d/cerbero

ENV HOME=/home/cerbero
# Mesmas env vars que o setup-cerbero-wslc.ps1 passa em runtime (-e) - aqui
# garantem que o RUN de "plugins install" abaixo escreva no MESMO lugar que o
# volume nomeado cerbero-extensions vai montar depois, em vez de cair num
# caminho default diferente.
ENV OPENCLAW_HOME=/home/cerbero
ENV OPENCLAW_STATE_DIR=/home/cerbero/.openclaw
ENV OPENCLAW_CONFIG_DIR=/home/cerbero/.openclaw

USER cerbero
WORKDIR /app

# Nao copiamos openclaw.json/.env para dentro da imagem: eles vivem nos volumes
# montados em /home/cerbero/.openclaw e /home/cerbero/.config/openclaw, para
# sobreviver a rebuilds/atualizacoes da imagem (mesma logica do docker-compose.yml
# oficial do OpenClaw, so que com o home do usuario "cerbero" em vez de "node").
# /tmp/openclaw (logs rolantes) tambem e mapeado - ver setup-cerbero-wslc.ps1 -
# porque por padrao /tmp nao persiste entre recriacoes do container.

# -----------------------------------------------------------------------------
# Pre-instala o plugin do WhatsApp DENTRO da imagem, em vez de baixar do
# ClawHub toda vez que o container sobe. Motivo: essa instalacao em runtime ja
# quebrou o canal inteiro uma vez (ClawHub passou a exigir um core do OpenClaw
# mais novo que a imagem tinha, e como o passo de bootstrap apaga o plugin
# antigo antes de reinstalar, ficamos sem WhatsApp ate a proxima imagem boa).
# Instalar aqui, no build, tem duas vantagens: (1) falha CEDO e visivelmente
# (o "wslc build" para e a tag "cerbero:local" nao avanca) em vez de falhar
# silenciosamente durante um restart; (2) um volume cerbero-extensions NOVO/
# VAZIO e populado automaticamente a partir do que esta na imagem no primeiro
# mount (comportamento padrao do Docker/WSLC pra volume vazio) - ou seja, o
# WhatsApp funciona mesmo se o ClawHub estiver fora do ar ou exigindo versao
# nova bem na hora do container subir. O setup-cerbero-wslc.ps1 ainda tenta
# uma atualizacao por cima em runtime, mas com backup/restore seguro - ver
# comentario la.
# "|| true": o ClawHub as vezes exige uma versao do core mais nova do que a
# tag "latest" publicada (ja aconteceu, ver historico deste arquivo) -- sem
# isso, o build inteiro falha. Deixamos best-effort aqui porque o volume
# cerbero-data persistente (extensions/whatsapp) e a fonte de verdade em
# runtime de qualquer forma -- se essa instalacao no build falhar, o plugin
# ja migrado no volume continua funcionando normalmente.
RUN node dist/index.js plugins install clawhub:@openclaw/whatsapp || echo "aviso: instalacao do plugin no build falhou (provavel desalinhamento de versao do ClawHub) - seguindo com o que estiver no volume persistente"

EXPOSE 18789

# CMD real do servico openclaw-gateway no docker-compose.yml oficial - sem o
# subcomando "gateway" (so "node dist/index.js"), o processo cai num modo de
# onboarding interativo que exige TTY e sai na hora quando rodado com -d.
# Para comandos avulsos de CLI (plugins install, models auth login, channels
# login), sobrescrevemos o CMD na hora de rodar - veja cerbero-cli.ps1.
CMD ["node", "dist/index.js", "gateway", "--bind", "lan", "--port", "18789"]

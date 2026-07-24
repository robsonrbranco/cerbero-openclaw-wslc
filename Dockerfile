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

FROM ghcr.io/openclaw/openclaw:latest

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

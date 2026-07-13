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
# em diagnostico dentro do container. Mantemos a lista curta de proposito.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg git curl jq \
    && rm -rf /var/lib/apt/lists/*

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

ENV HOME=/home/cerbero

USER cerbero
WORKDIR /app

# Nao copiamos openclaw.json/.env para dentro da imagem: eles vivem nos volumes
# montados em /home/cerbero/.openclaw e /home/cerbero/.config/openclaw, para
# sobreviver a rebuilds/atualizacoes da imagem (mesma logica do docker-compose.yml
# oficial do OpenClaw, so que com o home do usuario "cerbero" em vez de "node").
# /tmp/openclaw (logs rolantes) tambem e mapeado - ver setup-cerbero-wslc.ps1 -
# porque por padrao /tmp nao persiste entre recriacoes do container.

EXPOSE 18789 18790

# CMD real do servico openclaw-gateway no docker-compose.yml oficial - sem o
# subcomando "gateway" (so "node dist/index.js"), o processo cai num modo de
# onboarding interativo que exige TTY e sai na hora quando rodado com -d.
# Para comandos avulsos de CLI (plugins install, models auth login, channels
# login), sobrescrevemos o CMD na hora de rodar - veja cerbero-cli.ps1.
CMD ["node", "dist/index.js", "gateway", "--bind", "lan", "--port", "18789"]

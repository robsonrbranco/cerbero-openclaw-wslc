# wacli no Cerbero

O `wacli` roda como um segundo dispositivo vinculado, separado do plugin
WhatsApp do gateway. A imagem fixa a versao e valida o SHA-256 do artefato; o
sidecar grava sessao e indice em
`/home/cerbero/.openclaw/state/wacli`, dentro do PVC `cerbero-data`.

## Publicar e aplicar

Use o fluxo de CI normal do repositorio para publicar
`ghcr.io/robsonrbranco/cerbero-gateway:latest` e depois, no host que possui
acesso ao cluster:

```sh
kubectl apply -f k8s/cerbero.yaml
kubectl -n olympus rollout restart deployment/cerbero
kubectl -n olympus rollout status deployment/cerbero
```

## Primeiro pareamento

O sidecar fica esperando e nao abre o banco antes do pareamento. Gere o QR no
container principal, para que o terminal interativo nao dispute o lock com o
sidecar:

```sh
kubectl -n olympus exec -it deployment/cerbero -c cerbero -- wacli auth
```

No telefone do Branco: **WhatsApp > Dispositivos conectados > Conectar um
dispositivo**, e leia o QR. Em seguida:

```sh
kubectl -n olympus logs deployment/cerbero -c wacli-sync --tail=50
kubectl -n olympus exec deployment/cerbero -c cerbero -- wacli doctor --connect
kubectl -n olympus exec deployment/cerbero -c cerbero -- wacli-sampaio 3
```

O ultimo comando consulta somente o indice local com `WACLI_READONLY=1`; nao
envia mensagens, nao marca mensagens como lidas e nao altera o grupo.


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
kubectl -n olympus logs deployment/cerbero -c wacli-sync-branco --tail=50
kubectl -n olympus exec deployment/cerbero -c cerbero -- wacli doctor --connect
kubectl -n olympus exec deployment/cerbero -c cerbero -- wacli-sampaio 3
```

O ultimo comando consulta somente o indice local com `WACLI_READONLY=1`; nao
envia mensagens, nao marca mensagens como lidas e nao altera o grupo.

## Dois números, um sidecar para cada (29/09/2026)

| Número | Store | Sidecar | Teto |
|---|---|---|---|
| Branco (+55 21 99525-6856) | `state/wacli` (`WACLI_STORE_DIR`) | `wacli-sync-branco` | 2GB |
| Cerbero, dedicado (+55 21 97102-2207) | `state/wacli-cerbero` (`WACLI_STORE_DIR_CERBERO`) | `wacli-sync-cerbero` | 500MB |

O `wacli sync --follow` cuida de **um store só**, e cada store tem o seu lock:
dois números são dois processos, e cada um tem container próprio, que cai e
volta sozinho e tem log separado. O store do Branco manteve pasta e variável
porque `wacli-sampaio` e `wacli-base` leem por `WACLI_STORE_DIR`.

**Os dois rodam com `--presence-mode quiet`** — em `normal`, a sincronização
emite presença e os contatos veem o número "online" sem ninguém ali. **E com
`--max-db-size`:** ao chegar no teto o sync **para** (não apaga nada). Se um
espelho parar de atualizar, `wacli --store <pasta> doctor` mostra, e o
conserto é subir o teto no manifesto.

Parear o número do Cerbero, no celular dele (o caminho vai por extenso: sem
`sh -c`, as aspas não se perdem passando por PowerShell e ssh):

```sh
kubectl -n olympus exec -it deployment/cerbero -c cerbero -- wacli --store /home/cerbero/.openclaw/state/wacli-cerbero auth
kubectl -n olympus logs deployment/cerbero -c wacli-sync-cerbero --tail=20
```

Depois da primeira carga, `Ctrl+C`: enquanto o `auth` estiver aberto ele
segura o lock, e o sidecar só assume no ciclo seguinte.

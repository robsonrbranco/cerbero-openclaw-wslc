"""Autoriza o OAuth client do Cerbero para leitura do Google Cloud Storage
e grava o refresh token direto no Secret Manager.

Roda LOCALMENTE, na maquina do Branco. Nenhum segredo (client secret ou
refresh token) e impresso na tela nem gravado em arquivo solto -- o
client secret e lido do JSON baixado do console e o refresh token vai
direto pro Secret Manager.

Por que existe: o acesso ao bucket do WeatherNext esta atrelado a conta
pessoal (robson.branco@gmail.com), nao a service account -- ver
LICOES-APRENDIDAS.md item 49/50. O job em us-east1 precisa agir como
essa conta ate o Google liberar acesso pra SA.

Uso:
    python autorizar.py caminho/para/client_secret_xxx.json
"""

import json
import secrets
import subprocess
import sys
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer

PROJECT = "cerbero-502221"
SECRET_NAME = "weathernext-oauth-refresh-token"
SCOPES = ["https://www.googleapis.com/auth/devstorage.read_only"]
PORT = 8765
REDIRECT = f"http://localhost:{PORT}/"

_received = {}


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        query = urllib.parse.urlparse(self.path).query
        params = urllib.parse.parse_qs(query)
        _received.update({k: v[0] for k, v in params.items()})
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers()
        ok = "code" in _received
        msg = "Autorizado. Pode fechar esta aba." if ok else f"Falhou: {_received.get('error')}"
        self.wfile.write(f"<html><body><h2>{msg}</h2></body></html>".encode())

    def log_message(self, *args):
        pass  # silencia o log do servidor


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    with open(sys.argv[1], encoding="utf-8") as fh:
        blob = json.load(fh)
    cfg = blob.get("installed") or blob.get("web")
    if not cfg:
        print("JSON nao parece ser de um OAuth client (falta 'installed'/'web').")
        sys.exit(1)
    client_id = cfg["client_id"]
    client_secret = cfg["client_secret"]

    state = secrets.token_urlsafe(16)
    auth_url = "https://accounts.google.com/o/oauth2/v2/auth?" + urllib.parse.urlencode(
        {
            "client_id": client_id,
            "redirect_uri": REDIRECT,
            "response_type": "code",
            "scope": " ".join(SCOPES),
            "access_type": "offline",
            "prompt": "consent",
            "state": state,
        }
    )

    print("\nAbra esta URL no navegador (logado como robson.branco@gmail.com):\n")
    print(auth_url)
    print(f"\nAguardando o retorno em {REDIRECT} ...")

    server = HTTPServer(("localhost", PORT), Handler)
    server.handle_request()
    server.server_close()

    if _received.get("state") != state:
        print("ERRO: state nao confere (possivel CSRF). Abortado.")
        sys.exit(1)
    if "code" not in _received:
        print(f"ERRO: autorizacao falhou: {_received.get('error')}")
        sys.exit(1)

    body = urllib.parse.urlencode(
        {
            "code": _received["code"],
            "client_id": client_id,
            "client_secret": client_secret,
            "redirect_uri": REDIRECT,
            "grant_type": "authorization_code",
        }
    ).encode()
    req = urllib.request.Request(
        "https://oauth2.googleapis.com/token",
        data=body,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    with urllib.request.urlopen(req) as resp:
        tok = json.loads(resp.read().decode())

    if "refresh_token" not in tok:
        print(f"ERRO: resposta sem refresh_token: {list(tok)}")
        sys.exit(1)
    print(f"OK: refresh token obtido (escopos: {tok.get('scope')})")

    # O que o job precisa pra renovar sozinho, num unico segredo.
    payload = json.dumps(
        {
            "type": "authorized_user",
            "client_id": client_id,
            "client_secret": client_secret,
            "refresh_token": tok["refresh_token"],
        }
    )

    exists = subprocess.run(
        ["gcloud", "secrets", "describe", SECRET_NAME, f"--project={PROJECT}"],
        capture_output=True,
    ).returncode == 0
    if not exists:
        subprocess.run(
            ["gcloud", "secrets", "create", SECRET_NAME, f"--project={PROJECT}",
             "--replication-policy=automatic"],
            check=True,
        )
    proc = subprocess.run(
        ["gcloud", "secrets", "versions", "add", SECRET_NAME, f"--project={PROJECT}",
         "--data-file=-"],
        input=payload.encode(),
        capture_output=True,
    )
    if proc.returncode != 0:
        print("ERRO ao gravar no Secret Manager:", proc.stderr.decode()[:400])
        sys.exit(1)

    print(f"\nPronto: gravado em Secret Manager como '{SECRET_NAME}' no projeto {PROJECT}.")
    print("Nenhum segredo foi impresso nem salvo em arquivo por este script.")


if __name__ == "__main__":
    main()

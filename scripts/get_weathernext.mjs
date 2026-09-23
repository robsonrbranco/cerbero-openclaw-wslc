// Consulta o WeatherNext 3 (BigQuery) pra um ponto lat/lon, sem dependencias
// externas -- so stdlib do Node (crypto pra assinar o JWT da service account,
// https/fetch pra falar com as APIs do Google).
//
// Copia de referencia versionada no repo -- o arquivo de verdade que os
// crons chamam vive em /home/cerbero/.openclaw/workspace/get_weathernext.mjs
// (volume persistente, nao versionado, igual get_marine.py/get_weather.py).
// Atualizar aqui e la juntos.
//
// Uso: node get_weathernext.mjs <lat> <lon> [horas_a_frente] [--dry-run]
//   node get_weathernext.mjs -22.9020 -42.4864 36
//   --dry-run: descobre o init_time (~1 centavo) e so ESTIMA a consulta
//   principal, sem executa-la nem cobra-la.
//
// CUSTO -- leia antes de mexer na consulta (LICOES-APRENDIDAS.md item 49).
// A tabela e uma VIEW de dataset vinculado (Analytics Hub); o BigQuery cobra
// por bytes lidos, e o que decide o custo e o filtro em `init_time`. Medido
// por dry-run em 23/09/2026:
//
//   WHERE init_time = (SELECT MAX(init_time) FROM tabela)   ~156 TiB  ~US$ 973
//   WHERE init_time = TIMESTAMP('...') literal               ~300 GiB  ~US$ 1,83
//   SELECT MAX(init_time) ... WHERE init_time >= agora-2d      ~2 GiB  ~US$ 0,01
//
// A subconsulta com MAX sem filtro varre a tabela inteira -- o BigQuery nao
// poda particao por um valor que ele so conhece depois de ler tudo. Por isso
// sao DUAS consultas: descobre o init mais recente olhando so a janela
// recente, e consulta com ele como literal.
//
// E cada consulta leva `maximumBytesBilled`: se uma edicao futura trouxer de
// volta um padrao caro, o BigQuery RECUSA o job em vez de cobrar. O teto e a
// protecao que nao depende de ninguem lembrar desta nota.
//
// Credencial: le a service account key de $GCP_KEY_PATH (default
// /home/cerbero/.gcp/key.json, montado via Secret "weathernext-credentials",
// ver k8s/cerbero.yaml).

import { readFileSync } from "node:fs";
import { createSign } from "node:crypto";

const KEY_PATH = process.env.GCP_KEY_PATH || "/home/cerbero/.gcp/key.json";
const PROJECT_ID = process.env.GCP_PROJECT_ID || "cerbero-502221";
const DATASET = process.env.WEATHERNEXT_DATASET || "weathernext_3";
const TABLE = process.env.WEATHERNEXT_TABLE || "weathernext_3_0_0_0p1deg";

const GIB = 1024 ** 3;
// Tetos de faturamento por consulta. Folga de ~5x e ~1,6x sobre o medido --
// crescimento normal da tabela cabe, a volta do padrao de ~156 TiB nao.
const TETO_DESCOBERTA = 10 * GIB;
const TETO_CONSULTA = 500 * GIB;
// Janela olhada para achar o init mais recente. O modelo roda varias vezes
// por dia; 2 dias sobra, e e o que mantem a descoberta em ~2 GiB.
const JANELA_INIT_DIAS = 2;

function b64url(buf) {
  return Buffer.from(buf)
    .toString("base64")
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
}

async function getAccessToken(key) {
  const nowSec = Math.floor(Date.now() / 1000);
  const header = { alg: "RS256", typ: "JWT" };
  const claims = {
    iss: key.client_email,
    scope: "https://www.googleapis.com/auth/bigquery.readonly",
    aud: "https://oauth2.googleapis.com/token",
    iat: nowSec,
    exp: nowSec + 3600,
  };
  const signingInput = `${b64url(JSON.stringify(header))}.${b64url(JSON.stringify(claims))}`;
  const signer = createSign("RSA-SHA256");
  signer.update(signingInput);
  signer.end();
  const signature = b64url(signer.sign(key.private_key));
  const jwt = `${signingInput}.${signature}`;

  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion: jwt,
    }),
  });
  if (!res.ok) {
    throw new Error(`token exchange failed: ${res.status} ${await res.text()}`);
  }
  const data = await res.json();
  return data.access_token;
}

async function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function runQuery(token, sql, { tetoBytes, dryRun = false }) {
  if (!tetoBytes) {
    // Sem teto nao roda: e o que impede uma consulta nova de sair sem limite.
    throw new Error("runQuery exige tetoBytes");
  }
  const res = await fetch(
    `https://bigquery.googleapis.com/bigquery/v2/projects/${PROJECT_ID}/queries`,
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${token}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        query: sql,
        useLegacySql: false,
        timeoutMs: 10000,
        dryRun,
        maximumBytesBilled: String(tetoBytes),
      }),
    },
  );
  let data = await res.json();
  if (!res.ok) {
    throw new Error(`query failed: ${res.status} ${JSON.stringify(data)}`);
  }
  if (dryRun) {
    return data;
  }

  // Consulta contra a tabela do WeatherNext costuma nao terminar dentro do
  // wait sincrono da API (jobComplete:false) -- faz polling em
  // jobs.getQueryResults ate completar ou estourar o timeout local.
  const { jobId, location } = data.jobReference;
  const deadline = Date.now() + 60000;
  while (!data.jobComplete) {
    if (Date.now() > deadline) {
      throw new Error(`query timeout after 60s (jobId=${jobId})`);
    }
    await sleep(2000);
    const pollRes = await fetch(
      `https://bigquery.googleapis.com/bigquery/v2/projects/${PROJECT_ID}/queries/${jobId}?location=${location}`,
      { headers: { Authorization: `Bearer ${token}` } },
    );
    data = await pollRes.json();
    if (!pollRes.ok) {
      throw new Error(`poll failed: ${pollRes.status} ${JSON.stringify(data)}`);
    }
  }
  return data;
}

function rowsToObjects(result) {
  if (!result.schema) return [];
  const fields = result.schema.fields;
  return (result.rows || []).map((row) => {
    const obj = {};
    row.f.forEach((cell, i) => {
      obj[fields[i].name] = cell.v;
    });
    return obj;
  });
}

async function main() {
  const args = process.argv.slice(2);
  const dryRun = args.includes("--dry-run");
  const [latArg, lonArg, hoursArg] = args.filter((a) => a !== "--dry-run");
  if (!latArg || !lonArg) {
    console.error("Uso: node get_weathernext.mjs <lat> <lon> [horas_a_frente=48] [--dry-run]");
    process.exit(1);
  }
  const lat = Number(latArg);
  const lon = Number(lonArg);
  const maxHours = Number(hoursArg || 48);
  // Os tres entram na SQL por interpolacao: so numero passa.
  if (![lat, lon, maxHours].every(Number.isFinite)) {
    console.error(JSON.stringify({ ok: false, error: "lat, lon e horas precisam ser numeros" }));
    process.exit(1);
  }

  const key = JSON.parse(readFileSync(KEY_PATH, "utf8"));
  const token = await getAccessToken(key);
  const tabela = `\`${PROJECT_ID}.${DATASET}.${TABLE}\``;

  // 1) Descobre o init_time mais recente olhando SO a janela recente
  //    (~2 GiB). Ver a nota de custo no topo do arquivo.
  const descoberta = rowsToObjects(await runQuery(token, `
    SELECT CAST(MAX(init_time) AS STRING) AS init_time
    FROM ${tabela}
    WHERE init_time >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL ${JANELA_INIT_DIAS} DAY)
  `, { tetoBytes: TETO_DESCOBERTA }));
  const initTime = descoberta[0]?.init_time;
  if (!initTime) {
    console.log(JSON.stringify({
      ok: false,
      reason: `nenhum init_time nos ultimos ${JANELA_INIT_DIAS} dias -- dataset parado?`,
    }));
    return;
  }

  // 2) Consulta a celula de grade que contem o ponto, com o init como
  //    LITERAL -- e isso que faz o BigQuery ler ~300 GiB e nao ~156 TiB.
  //    `initTime` vem do proprio BigQuery e so contem data/hora.
  const sql = `
    SELECT
      f.time AS forecast_time,
      f.hours AS forecast_hour,
      ROUND(f.temperature_2m_mean - 273.15, 1) AS temp_c,
      ROUND(f.wind_speed_10m_mean, 1) AS wind_speed_mps,
      ROUND(f.wind_speed_10m_mean * 3.6, 1) AS wind_speed_kmh,
      ROUND(f.total_precipitation_1hr_mean * 1000, 2) AS precip_1hr_mm
    FROM ${tabela} AS t, t.forecast AS f
    WHERE t.init_time = TIMESTAMP('${initTime}')
    AND ST_INTERSECTS(t.geography_polygon, ST_GEOGPOINT(${lon}, ${lat}))
    AND f.hours <= ${maxHours}
    ORDER BY f.time ASC
  `;

  if (dryRun) {
    const est = await runQuery(token, sql, { tetoBytes: TETO_CONSULTA, dryRun: true });
    const bytes = Number(est.totalBytesProcessed);
    console.log(JSON.stringify({
      ok: true, dryRun: true, init_time: initTime,
      estimativa_gib: +(bytes / GIB).toFixed(1),
      estimativa_usd: +((bytes / 1024 ** 4) * 6.25).toFixed(2),
      teto_gib: TETO_CONSULTA / GIB,
    }, null, 2));
    return;
  }

  const result = await runQuery(token, sql, { tetoBytes: TETO_CONSULTA });
  const rows = rowsToObjects(result);
  if (!rows.length) {
    console.log(JSON.stringify({ ok: false, reason: "sem linhas retornadas para esse ponto/horizonte" }));
    return;
  }
  console.log(JSON.stringify({ ok: true, point: { lat, lon }, table: TABLE, init_time: initTime, forecasts: rows }, null, 2));
}

main().catch((err) => {
  console.error(JSON.stringify({ ok: false, error: String(err) }));
  process.exit(1);
});

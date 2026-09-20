// Consulta o WeatherNext 3 (BigQuery) pra um ponto lat/lon, sem dependencias
// externas -- so stdlib do Node (crypto pra assinar o JWT da service account,
// https/fetch pra falar com as APIs do Google).
//
// Copia de referencia versionada no repo -- o arquivo de verdade que os
// crons chamam vive em /home/cerbero/.openclaw/workspace/get_weathernext.mjs
// (volume persistente, nao versionado, igual get_marine.py/get_weather.py).
// Atualizar aqui e la juntos.
//
// Uso: node get_weathernext.mjs <lat> <lon> [horas_a_frente]
//   node get_weathernext.mjs -22.9020 -42.4864 36
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

async function runQuery(token, sql) {
  const res = await fetch(
    `https://bigquery.googleapis.com/bigquery/v2/projects/${PROJECT_ID}/queries`,
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${token}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ query: sql, useLegacySql: false, timeoutMs: 10000 }),
    },
  );
  let data = await res.json();
  if (!res.ok) {
    throw new Error(`query failed: ${res.status} ${JSON.stringify(data)}`);
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
  const [latArg, lonArg, hoursArg] = process.argv.slice(2);
  if (!latArg || !lonArg) {
    console.error("Uso: node get_weathernext.mjs <lat> <lon> [horas_a_frente=48]");
    process.exit(1);
  }
  const lat = Number(latArg);
  const lon = Number(lonArg);
  const maxHours = Number(hoursArg || 48);

  const key = JSON.parse(readFileSync(KEY_PATH, "utf8"));
  const token = await getAccessToken(key);

  // Pega o ultimo init_time disponivel (a previsao mais recente rodada pelo
  // modelo) e extrai a celula de grade que contem o ponto pedido.
  const sql = `
    SELECT
      f.time AS forecast_time,
      f.hours AS forecast_hour,
      ROUND(f.temperature_2m_mean - 273.15, 1) AS temp_c,
      ROUND(f.wind_speed_10m_mean, 1) AS wind_speed_mps,
      ROUND(f.wind_speed_10m_mean * 3.6, 1) AS wind_speed_kmh,
      ROUND(f.total_precipitation_1hr_mean * 1000, 2) AS precip_1hr_mm
    FROM \`${PROJECT_ID}.${DATASET}.${TABLE}\` AS t, t.forecast AS f
    WHERE t.init_time = (
      SELECT MAX(init_time)
      FROM \`${PROJECT_ID}.${DATASET}.${TABLE}\`
    )
    AND ST_INTERSECTS(t.geography_polygon, ST_GEOGPOINT(${lon}, ${lat}))
    AND f.hours <= ${maxHours}
    ORDER BY f.time ASC
  `;

  const result = await runQuery(token, sql);
  const rows = rowsToObjects(result);
  if (!rows.length) {
    console.log(JSON.stringify({ ok: false, reason: "sem linhas retornadas para esse ponto/horizonte" }));
    return;
  }
  console.log(JSON.stringify({ ok: true, point: { lat, lon }, table: TABLE, forecasts: rows }, null, 2));
}

main().catch((err) => {
  console.error(JSON.stringify({ ok: false, error: String(err) }));
  process.exit(1);
});

"""Job Cloud Run (us-east1) que le o WeatherNext 3 e publica um JSON enxuto
com o perfil atmosferico dos sitios de voo livre.

Por que rodar em us-east1: o chunk do Zarr do WeatherNext e GLOBAL (cada
chunk cobre a Terra inteira para 1 membro x 1 lead_time x 1 nivel, 4.2 MB
em 0.25 graus). Ler um unico ponto com 64 membros custa ~3,5 GB de egress
-- e o bucket e Requester Pays. Colocado no us-east1, esse trafego e
gratuito, e so o JSON final (alguns KB) sai da regiao.
Ver LICOES-APRENDIDAS.md item 49.

Saida: gs://cerbero-weathernext-results/latest.json (+ copia com timestamp)
"""

import json
import logging
import os
from datetime import datetime, timedelta, timezone

import gcsfs
import numpy as np
import xarray as xr
from google.cloud import storage
from metpy.calc import potential_temperature, wind_direction, wind_speed
from metpy.units import units

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("weathernext-job")

PROJECT = os.environ.get("GCP_PROJECT", "cerbero-502221")
OUT_BUCKET = os.environ.get("OUT_BUCKET", "cerbero-weathernext-results")
SRC = "gs://weathernext3_spatial/weathernext_3_0_0/zarr/2026_to_present/"

# Quantos membros do ensemble ler. Colocado na regiao o egress e de graca,
# mas cada membro ainda custa tempo/memoria: 13 niveis x 4.2 MB por membro.
N_MEMBERS = int(os.environ.get("N_MEMBERS", "16"))

# Niveis que interessam pra voo livre (acima de 500 hPa ~5500m nao importa).
LEVELS = [1000, 925, 850, 700, 600, 500]

SITES = {
    "parapente-br-rj-niteroi-parque-cidade": {
        "nome": "Rampa do Parque da Cidade, Niteroi/RJ",
        "lat": -22.9298772,
        "lon": -43.0901203,
        "altitude_m": 270,
        "tipo_voo": "lift",
        "janela_analise": "08-17h",
    },
    "parapente-br-rj-saquarema-sampaio-correa": {
        "nome": "Rampa de Sampaio Correia (Norte), Saquarema/RJ",
        "lat": -22.8589728,
        "lon": -42.6403429,
        "altitude_m": 720,
        "tipo_voo": "xc-termico",
        "janela_analise": "11-14h",
    },
}


def find_latest_synoptic_init(fs):
    """Acha o init sinotico (00/06/12/18Z) mais recente que ja existe.

    So os sinoticos trazem os 13 niveis de pressao -- os inits horarios
    intermediarios tem apenas superficie (horizonte 48h).
    """
    now = datetime.now(timezone.utc).replace(tzinfo=None)
    for hours_back in range(0, 96):
        t = now - timedelta(hours=hours_back)
        if t.hour not in (0, 6, 12, 18):
            continue
        path = f"{SRC}{t:%Y%m%d}_{t:%H}hr_01_preds"
        if fs.exists(path):
            # O grupo Zarr fica um nivel abaixo do diretorio do init.
            return f"{path}/predictions.zarr", t
    raise RuntimeError("nenhum init sinotico encontrado nas ultimas 96h")


def profile_for_point(sub, lat, lon, levels):
    """Extrai e agrega o perfil de um ponto. sub ja vem com membros/niveis
    recortados -- o .compute() aqui e o unico momento que baixa dado."""
    point = sub.sel(lat_0p25=lat, lon_0p25=lon % 360, method="nearest").compute()

    glat = float(point["lat_0p25"].values)
    glon = float(point["lon_0p25"].values)
    glon_signed = glon - 360 if glon > 180 else glon
    dist_km = float(
        np.hypot((glat - lat) * 111.32, (glon_signed - lon) * 111.32 * np.cos(np.radians(lat)))
    )

    u_all = point["u_component_of_wind"].values  # (sample, level)
    v_all = point["v_component_of_wind"].values
    t_all = point["temperature"].values

    u, v, t_k = u_all.mean(axis=0), v_all.mean(axis=0), t_all.mean(axis=0)
    lv = np.array(levels)

    spd = wind_speed(u * units("m/s"), v * units("m/s")).to("km/h").magnitude
    drc = wind_direction(u * units("m/s"), v * units("m/s")).magnitude
    theta = potential_temperature(lv * units.hPa, t_k * units.K).to("degC").magnitude
    alt = 44330 * (1 - (lv / 1013.25) ** 0.1903)

    # Spread do ensemble na velocidade = sinal de (in)certeza da previsao.
    spd_sd = (np.hypot(u_all, v_all) * 3.6).std(axis=0)

    niveis = []
    for i, level in enumerate(levels):
        niveis.append(
            {
                "nivel_hpa": int(level),
                "altitude_aprox_m": round(float(alt[i])),
                "temperatura_c": round(float(t_k[i] - 273.15), 1),
                "theta_c": round(float(theta[i]), 1),
                "vento_kmh": round(float(spd[i]), 1),
                "vento_spread_kmh": round(float(spd_sd[i]), 1),
                "vento_dir_graus": round(float(drc[i])),
            }
        )

    idx = {level: i for i, level in enumerate(levels)}
    d_925 = float(theta[idx[925]] - theta[idx[1000]])
    d_850 = float(theta[idx[850]] - theta[idx[1000]])
    shear = abs(float(spd[idx[850]] - spd[idx[1000]]))

    if d_925 < 1.0:
        mistura = "bem-misturada"
    elif d_925 > 3.0:
        mistura = "estavel-possivel-inversao"
    else:
        mistura = "intermediaria"

    return {
        "celula_grade": {
            "lat": round(glat, 3),
            "lon": round(glon_signed, 3),
            "distancia_do_ponto_km": round(dist_km, 1),
            "resolucao_graus": 0.25,
            "aviso": (
                "celula de ~28 km; em sitio costeiro pode cair sobre agua e "
                "subestimar o potencial termico"
            ),
        },
        "niveis": niveis,
        "indices": {
            "delta_theta_1000_925_c": round(d_925, 2),
            "delta_theta_1000_850_c": round(d_850, 2),
            "cisalhamento_1000_850_kmh": round(shear, 1),
            "camada_baixa": mistura,
        },
    }


def main():
    fs = gcsfs.GCSFileSystem(project=PROJECT, requester_pays=True)
    zarr_path, init_dt = find_latest_synoptic_init(fs)
    log.info("init sinotico: %s", zarr_path)

    ds = xr.open_zarr(fs.get_mapper(zarr_path), consolidated=False)
    levels_all = list(int(x) for x in ds["level"].values)
    lev_idx = [levels_all.index(level) for level in LEVELS]

    n_members = min(N_MEMBERS, ds.sizes["sample"])
    log.info("lendo %d membros x %d niveis", n_members, len(LEVELS))

    resultado = {
        "gerado_em": datetime.now(timezone.utc).isoformat(),
        "modelo": "weathernext_3_0_0",
        "init_utc": init_dt.isoformat(),
        "membros_ensemble": n_members,
        "fonte": zarr_path,
        "horizontes": [],
    }

    # Lead times 0..3 do init sinotico cobrem ~6h..24h a frente, suficiente
    # pros boletins do dia seguinte. Cada lead_time extra multiplica o custo.
    for lead_idx in range(0, 4):
        valid = np.datetime64(ds["datetime"].isel(lead_time=lead_idx).values)
        valid_brt = valid - np.timedelta64(3, "h")

        sub = ds[["u_component_of_wind", "v_component_of_wind", "temperature"]].isel(
            sample=slice(0, n_members), lead_time=lead_idx, level=lev_idx
        )

        sitios = {}
        for site_id, cfg in SITES.items():
            log.info("lead %d | %s", lead_idx, site_id)
            perfil = profile_for_point(sub, cfg["lat"], cfg["lon"], LEVELS)
            perfil["sitio"] = {k: v for k, v in cfg.items()}
            sitios[site_id] = perfil

        resultado["horizontes"].append(
            {
                "lead_index": lead_idx,
                "valido_utc": str(np.datetime_as_string(valid, unit="m")),
                "valido_brt": str(np.datetime_as_string(valid_brt, unit="m")),
                "sitios": sitios,
            }
        )

    payload = json.dumps(resultado, ensure_ascii=False, indent=2)
    client = storage.Client(project=PROJECT)
    bucket = client.bucket(OUT_BUCKET)
    stamp = f"{init_dt:%Y%m%dT%H}Z"
    for name in ("latest.json", f"history/{stamp}.json"):
        bucket.blob(name).upload_from_string(payload, content_type="application/json")
    log.info("publicado: gs://%s/latest.json (%d bytes)", OUT_BUCKET, len(payload))


if __name__ == "__main__":
    main()

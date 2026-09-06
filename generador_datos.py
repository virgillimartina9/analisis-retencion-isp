"""
Generador de datos ficticios - Proyecto "Retención de clientes en un ISP cooperativo"
Genera 4 CSV: planes, clientes, facturacion, tickets.

Los datos incluyen señal real (el churn NO es aleatorio) y suciedad intencional
para que el proceso de limpieza sea parte demostrable del proyecto.

Uso:  python generador_datos.py
Salida: ./datos/*.csv
"""

import os
import numpy as np
import pandas as pd

SEED = 42
rng = np.random.default_rng(SEED)
OUT = "datos"
os.makedirs(OUT, exist_ok=True)

MESES = pd.period_range("2024-08", "2026-07", freq="M")
N_MESES = len(MESES)

# ---------------------------------------------------------------- PLANES
PLANES = pd.DataFrame(
    [
        ("P01", "Básico 50", "Residencial", 50, 22000),
        ("P02", "Estándar 100", "Residencial", 100, 30000),
        ("P03", "Plus 300", "Residencial", 300, 42000),
        ("P04", "Premium 600", "Residencial", 600, 58000),
        ("P05", "Fibra Total 1000", "Residencial", 1000, 75000),
        ("P06", "Empresa 500", "Comercial", 500, 95000),
    ],
    columns=["id_plan", "nombre_plan", "tipo_plan", "velocidad_mbps", "precio_base"],
)
PRECIO = dict(zip(PLANES.id_plan, PLANES.precio_base))

# Indice de precios: ajuste de tarifas cada 4 meses (+9%)
indice = {}
val = 1.0
for i, m in enumerate(MESES):
    if i > 0 and i % 4 == 0:
        val *= 1.09
    indice[m] = round(val, 4)

# ---------------------------------------------------------------- LOCALIDADES
LOC = ["Pinamar", "Ostende", "Valeria del Mar", "Cariló", "Mar de Ostende", "General Madariaga"]
LOC_P = [0.40, 0.15, 0.15, 0.12, 0.10, 0.08]
# calidad de infraestructura (variable OCULTA: no se exporta, pero explica los datos)
INFRA = {
    "Pinamar": 0.90,
    "Ostende": 0.75,
    "Valeria del Mar": 0.70,
    "Cariló": 0.85,
    "Mar de Ostende": 0.55,
    "General Madariaga": 0.50,
}
CANALES_ALTA = ["Sucursal", "Web", "Telefónico", "Vendedor", "Referido"]
CANALES_ALTA_P = [0.35, 0.20, 0.18, 0.15, 0.12]

# ---------------------------------------------------------------- CLIENTES
N_BASE = 4200          # activos al inicio de la ventana
ALTAS_MES = 42         # altas promedio por mes

clientes = []
cid = 1000


def nuevo_cliente(fecha_alta):
    global cid
    cid += 1
    loc = rng.choice(LOC, p=LOC_P)
    tipo = "Comercial" if rng.random() < 0.12 else "Residencial"
    if tipo == "Comercial":
        plan = "P06" if rng.random() < 0.8 else "P05"
    else:
        plan = rng.choice(["P01", "P02", "P03", "P04", "P05"], p=[0.26, 0.32, 0.22, 0.13, 0.07])
    estacional = (
        tipo == "Residencial"
        and loc in ("Cariló", "Valeria del Mar", "Mar de Ostende")
        and rng.random() < 0.35
    )
    return {
        "id_cliente": f"C{cid}",
        "localidad": loc,
        "tipo_cliente": tipo,
        "id_plan": plan,
        "fecha_alta": fecha_alta,
        "canal_alta": rng.choice(CANALES_ALTA, p=CANALES_ALTA_P),
        "_infra": INFRA[loc],
        "_estacional": estacional,
        "_prop_mora": float(np.clip(rng.beta(1.6, 9), 0, 0.85)),
        "fecha_baja": pd.NaT,
        "motivo_baja": None,
    }


inicio = MESES[0].start_time
for _ in range(N_BASE):
    antig_dias = int(rng.gamma(2.0, 500))          # antigüedad previa
    clientes.append(nuevo_cliente(inicio - pd.Timedelta(days=antig_dias + 30)))

altas_por_mes = {}
for m in MESES:
    n = rng.poisson(ALTAS_MES)
    altas_por_mes[m] = n
    for _ in range(n):
        dia = int(rng.integers(1, 28))
        clientes.append(nuevo_cliente(m.start_time + pd.Timedelta(days=dia - 1)))

cli = {c["id_cliente"]: c for c in clientes}

# ---------------------------------------------------------------- SIMULACIÓN MES A MES
CATEGORIAS = [
    "Sin conexión",
    "Conexión lenta / intermitencia",
    "WiFi / equipos",
    "Facturación",
    "Instalación",
    "Cambio de plan",
    "Consulta comercial",
    "Corte programado",
]
CAT_TECNICAS = {"Sin conexión", "Conexión lenta / intermitencia", "WiFi / equipos"}
CAT_P = [0.22, 0.24, 0.14, 0.13, 0.06, 0.07, 0.09, 0.05]
CANAL_TK = ["Telefónico", "WhatsApp", "Sucursal", "Portal web", "Email"]
CANAL_TK_P = [0.42, 0.26, 0.14, 0.12, 0.06]

facturas, tickets = [], []
fid, tid = 500000, 900000

hist_tickets_tec = {k: [] for k in cli}      # meses con tickets técnicos
hist_impagas = {k: 0 for k in cli}

for mi, m in enumerate(MESES):
    mes_num = m.month
    verano = mes_num in (12, 1, 2)
    for k, c in cli.items():
        if c["fecha_alta"] > m.end_time:
            continue
        if pd.notna(c["fecha_baja"]) and c["fecha_baja"] < m.start_time:
            continue

        # ---------- TICKETS ----------
        lam = 0.30 * (1.65 - c["_infra"])
        if verano:
            lam *= 1.55
        if c["tipo_cliente"] == "Comercial":
            lam *= 1.30
        n_tk = rng.poisson(lam)
        tec_este_mes = 0
        for _ in range(n_tk):
            tid += 1
            cat = rng.choice(CATEGORIAS, p=CAT_P)
            es_tec = cat in CAT_TECNICAS
            tec_este_mes += int(es_tec)
            prio = rng.choice(["Alta", "Media", "Baja"], p=[0.25, 0.5, 0.25] if es_tec else [0.08, 0.42, 0.5])
            dia = int(rng.integers(1, m.days_in_month + 1))
            hora = int(rng.integers(8, 21))
            apertura = m.start_time + pd.Timedelta(days=dia - 1, hours=hora)

            base_h = {"Alta": 6, "Media": 20, "Baja": 46}[prio]
            base_h *= (1.7 - c["_infra"])
            if verano:
                base_h *= 1.45                       # temporada alta satura la mesa
            horas = float(np.clip(rng.lognormal(np.log(base_h), 0.62), 0.5, 700))
            abierto = (mi >= N_MESES - 1) and rng.random() < 0.35
            cierre = pd.NaT if abierto else apertura + pd.Timedelta(hours=horas)

            if abierto:
                sat = np.nan
            else:
                base_sat = 5 - min(4, horas / 26)
                sat = float(np.clip(rng.normal(base_sat, 0.9), 1, 5))
                sat = round(sat)
                if rng.random() < 0.42:
                    sat = np.nan
            tickets.append(
                {
                    "id_ticket": f"T{tid}",
                    "id_cliente": k,
                    "fecha_apertura": apertura,
                    "fecha_cierre": cierre,
                    "categoria": cat,
                    "canal": rng.choice(CANAL_TK, p=CANAL_TK_P),
                    "prioridad": prio,
                    "satisfaccion": sat,
                }
            )
        hist_tickets_tec[k].append(tec_este_mes)

        # ---------- FACTURA ----------
        fid += 1
        monto = round(PRECIO[c["id_plan"]] * indice[m] * rng.normal(1.0, 0.02), 2)
        venc = (m + 1).start_time + pd.Timedelta(days=9)
        p_impago = float(np.clip(c["_prop_mora"] * (1.35 if verano else 1.0), 0, 0.9))
        if rng.random() < p_impago:
            pago = pd.NaT
            hist_impagas[k] += 1
        else:
            atraso = max(0, int(rng.normal(-4, 9)))
            pago = venc + pd.Timedelta(days=atraso)
            if pago > pd.Timestamp("2026-08-20"):
                pago = pd.NaT
            hist_impagas[k] = 0
        facturas.append(
            {
                "id_factura": f"F{fid}",
                "id_cliente": k,
                "periodo": str(m),
                "id_plan": c["id_plan"],
                "monto": monto,
                "fecha_vencimiento": venc,
                "fecha_pago": pago,
                "medio_pago": rng.choice(
                    ["Débito automático", "Transferencia", "Mercado Pago", "Efectivo / Sucursal", "Tarjeta"],
                    p=[0.38, 0.22, 0.18, 0.14, 0.08],
                )
                if pd.notna(pago)
                else None,
            }
        )

        # ---------- CHURN ----------
        tec90 = sum(hist_tickets_tec[k][-3:])
        h = 0.0042
        h *= 1 + 0.95 * min(tec90, 6)
        h *= 1 + 1.30 * min(hist_impagas[k], 3)
        h *= 2.05 - c["_infra"]
        antig_anios = (m.end_time - c["fecha_alta"]).days / 365
        h *= 0.72 if antig_anios > 5 else (1.45 if antig_anios < 1 else 1.0)
        if c["id_plan"] == "P01":
            h *= 1.30
        if c["tipo_cliente"] == "Comercial":
            h *= 0.55
        if c["_estacional"] and mes_num in (3, 4):
            h *= 5.5
        h = min(h, 0.30)

        if rng.random() < h:
            dia = int(rng.integers(1, m.days_in_month + 1))
            c["fecha_baja"] = m.start_time + pd.Timedelta(days=dia - 1)
            if hist_impagas[k] >= 2:
                mot = "Falta de pago"
            elif tec90 >= 3:
                mot = "Disconformidad con el servicio"
            elif c["_estacional"]:
                mot = "Fin de temporada"
            else:
                mot = rng.choice(
                    ["Se muda", "Precio", "Competencia", "Disconformidad con el servicio", "Sin motivo declarado"],
                    p=[0.24, 0.26, 0.22, 0.14, 0.14],
                )
            c["motivo_baja"] = mot

df_cli = pd.DataFrame(clientes)
df_fac = pd.DataFrame(facturas)
df_tk = pd.DataFrame(tickets)

# ---------------------------------------------------------------- DATOS DE CONTACTO
def mail(i):
    if rng.random() < 0.09:
        return None
    dom = rng.choice(["gmail.com", "hotmail.com", "telpin.com.ar", "yahoo.com.ar"], p=[0.5, 0.28, 0.14, 0.08])
    return f"cliente{i}@{dom}"


df_cli["email"] = [mail(i) for i in range(len(df_cli))]
df_cli["telefono"] = [
    None
    if rng.random() < 0.12
    else rng.choice(["02254-", "+54 2254 ", "2254"]) + str(int(rng.integers(400000, 499999)))
    for _ in range(len(df_cli))
]

# ---------------------------------------------------------------- SUCIEDAD INTENCIONAL
def ensuciar_localidad(v):
    r = rng.random()
    if r < 0.05:
        return v.upper()
    if r < 0.09:
        return v.lower()
    if r < 0.12:
        return f"  {v} "
    if r < 0.145:
        return v.replace("í", "i").replace("ó", "o")   # Cariló -> Carilo
    return v


df_cli["localidad"] = df_cli["localidad"].map(ensuciar_localidad)
df_cli["tipo_cliente"] = [
    v.upper() if rng.random() < 0.06 else (v.lower() if rng.random() < 0.06 else v)
    for v in df_cli["tipo_cliente"]
]

# fecha_pago con formatos mezclados (columna de texto)
def fmt_pago(x):
    if pd.isna(x):
        return None
    return x.strftime("%d/%m/%Y") if rng.random() < 0.18 else x.strftime("%Y-%m-%d")


df_fac["fecha_pago"] = df_fac["fecha_pago"].map(fmt_pago)
df_fac["fecha_vencimiento"] = df_fac["fecha_vencimiento"].dt.strftime("%Y-%m-%d")

# notas de crédito y outliers de carga
idx = rng.choice(df_fac.index, 34, replace=False)
df_fac.loc[idx, "monto"] = -df_fac.loc[idx, "monto"].abs().round(2)
idx = rng.choice(df_fac.index, 12, replace=False)
df_fac.loc[idx, "monto"] = (df_fac.loc[idx, "monto"] * 100).round(2)

# duplicados exactos de facturación
dups = df_fac.sample(480, random_state=SEED)
df_fac = pd.concat([df_fac, dups], ignore_index=True).sample(frac=1, random_state=SEED).reset_index(drop=True)

# tickets huérfanos (id_cliente inexistente)
huerf = df_tk.sample(90, random_state=SEED).copy()
huerf["id_cliente"] = [f"C{int(rng.integers(90000, 99999))}" for _ in range(len(huerf))]
huerf["id_ticket"] = [f"T{int(rng.integers(990000, 999999))}" for _ in range(len(huerf))]
df_tk = pd.concat([df_tk, huerf], ignore_index=True)

# satisfacción con valores inválidos
idx = rng.choice(df_tk.index, 60, replace=False)
df_tk.loc[idx, "satisfaccion"] = rng.choice([0, 6, 99], size=60)

df_tk["fecha_apertura"] = df_tk["fecha_apertura"].dt.strftime("%Y-%m-%d %H:%M:%S")
df_tk["fecha_cierre"] = df_tk["fecha_cierre"].dt.strftime("%Y-%m-%d %H:%M:%S")
df_tk = df_tk.sample(frac=1, random_state=SEED).reset_index(drop=True)

# ---------------------------------------------------------------- EXPORT
df_cli_out = df_cli.drop(columns=["_infra", "_estacional", "_prop_mora"]).copy()
df_cli_out["fecha_alta"] = df_cli_out["fecha_alta"].dt.strftime("%Y-%m-%d")
df_cli_out["fecha_baja"] = df_cli_out["fecha_baja"].dt.strftime("%Y-%m-%d")
df_cli_out = df_cli_out[
    ["id_cliente", "tipo_cliente", "localidad", "id_plan", "fecha_alta", "fecha_baja",
     "motivo_baja", "canal_alta", "email", "telefono"]
]

PLANES.to_csv(f"{OUT}/planes.csv", index=False)
df_cli_out.to_csv(f"{OUT}/clientes.csv", index=False)
df_fac.to_csv(f"{OUT}/facturacion.csv", index=False)
df_tk.to_csv(f"{OUT}/tickets.csv", index=False)

# ---------------------------------------------------------------- RESUMEN
activos = df_cli_out.fecha_baja.isna().sum()
print("clientes      :", len(df_cli_out), "| activos:", activos, "| bajas:", len(df_cli_out) - activos)
print("facturacion   :", len(df_fac), "| impagas:", df_fac.fecha_pago.isna().mean().round(3))
print("tickets       :", len(df_tk))
print("churn total   :", round((len(df_cli_out) - activos) / len(df_cli_out) * 100, 1), "%")
print("\nbajas por motivo:\n", df_cli_out.motivo_baja.value_counts())
print("\nchurn por localidad:")
tmp = df_cli_out.copy()
tmp["loc"] = tmp.localidad.str.strip().str.title().str.replace("Carilo", "Cariló")
print((tmp.assign(baja=tmp.fecha_baja.notna()).groupby("loc").baja.mean() * 100).round(1))

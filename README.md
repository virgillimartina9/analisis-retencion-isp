*[English version below]*

# Análisis de Retención de Clientes en un ISP

> Identificación de los factores que explican la baja de clientes en un proveedor
> de internet, y priorización de cuentas en riesgo para acción comercial.

<!-- ⬇ REEMPLAZAR por la captura del dashboard cuando esté lista.
     Va acá arriba, antes de cualquier texto: es lo primero que mira un
     seleccionador y muchas veces lo único.
     Guardarla en powerbi/capturas/dashboard_resumen.png -->

![Dashboard de retención](powerbi/capturas/dashboard_resumen.png)

**[Ver dashboard interactivo](URL_DE_POWER_BI_SERVICE)** · **[Informe ejecutivo (PDF)](docs/informe_ejecutivo.pdf)**

---

## Contexto

Una cooperativa de telecomunicaciones que presta servicio de internet en la costa
atlántica argentina perdió una parte relevante de su base de clientes en los
últimos 24 meses. La dirección necesita entender el fenómeno para decidir dónde
invertir: ¿es un problema de precio, de competencia, o de calidad de servicio?

**Preguntas de negocio:**

1. ¿Cuál es la tasa de churn mensual y cómo evolucionó?
2. ¿Se concentra en alguna localidad, plan o segmento de cliente?
3. ¿Qué relación hay entre los reclamos técnicos y las bajas?
4. ¿Y entre la morosidad y las bajas?
5. ¿Cuánto ingreso mensual recurrente se perdió?
6. ¿Qué clientes activos hoy están en riesgo y deberían contactarse primero?

> **Nota sobre los datos:** el dataset es **sintético**, generado con el script
> [`generador_datos.py`](generador_datos.py) incluido en este repositorio. No
> proviene de ninguna organización real. El modelo de negocio, las categorías de
> reclamo y la estacionalidad están basados en el funcionamiento habitual del
> sector.

---

## Datos

Cuatro tablas, 24 meses de historia (2024-08 a 2026-07):

| Tabla | Registros | Contenido |
|---|---|---|
| `clientes` | 5.215 | Alta, baja, motivo, plan, localidad, canal de captación |
| `planes` | 6 | Catálogo de planes y precios |
| `facturacion` | 101.300 | Facturación mensual, vencimientos y cobranza |
| `tickets` | 31.341 | Reclamos: categoría, canal, prioridad, resolución, satisfacción |

Diccionario de datos completo en [`docs/diccionario_datos.md`](docs/diccionario_datos.md).

---

## Metodología

| Fase | Herramienta | Qué se hizo |
|---|---|---|
| 1. Modelado e ingesta | SQL Server | Esquema estrella con staging previo; carga masiva desde CSV |
| 2. Control de calidad | SQL Server | 10 controles cuantificados sobre la capa staging |
| 3. Transformación | SQL Server | Limpieza, normalización y carga al modelo final |
| 4. Análisis exploratorio | Python / Pandas | Validación de hipótesis y construcción de la tabla analítica |
| 5. Visualización | Power BI | Modelo dimensional, medidas DAX y dashboard de 3 páginas |

**Decisión de arquitectura:** los datos se ingestan primero en una capa staging
sin tipar y recién se transforman después de medir los problemas de calidad. Esto
permite cuantificar la suciedad del origen en lugar de que la carga falle sin
diagnóstico.

---

## Problemas de calidad encontrados

<!-- ⬇ COMPLETAR con los resultados reales de sql/03_calidad_datos.sql.
     Esta sección es la que más valoran los seleccionadores y la que casi nadie
     escribe. La columna "Decisión" es la más importante: detectar un problema
     es fácil, justificar qué se hizo con él es lo que distingue el criterio. -->

| Problema | Registros | % | Decisión tomada |
|---|---|---|---|
| Filas duplicadas exactas en facturación | | | |
| Tickets con cliente inexistente | | | |
| `fecha_pago` en formato inconsistente | | | |
| Montos negativos | | | |
| Montos con error de carga (×100) | | | |
| `satisfaccion` fuera del rango 1-5 | | | |
| Variantes de escritura en `localidad` | | | |
| Variantes de escritura en `tipo_cliente` | | | |
| Nulos en datos de contacto | | | |

**Sesgo metodológico detectado y corregido:**

<!-- ⬇ COMPLETAR. Contar el sesgo de exposición: al contar tickets totales por
     cliente, los que se dieron de baja temprano acumulan menos tickets
     simplemente porque estuvieron menos meses activos, lo que invierte la
     relación real. La corrección fue medir en una ventana fija de 90 días
     previos al fin de la relación. Explicarlo con tus propios números. -->

---

## Hallazgos principales

<!-- ⬇ COMPLETAR con 4 o 5 bullets, cada uno con su número.
     Escribir la conclusión, no la descripción:
       MAL  → "Se analizó la relación entre tickets y churn."
       BIEN → "Los clientes con 3+ reclamos técnicos en 90 días se dan de baja
               en un 56%, frente al 16% del resto." -->

1.
2.
3.
4.

---

## Recomendaciones

<!-- ⬇ COMPLETAR con 3 recomendaciones accionables, cada una con su impacto
     estimado en dinero o en clientes retenidos. Una recomendación sin número
     al lado es una opinión. -->

1.
2.
3.

---

## Stack

`SQL Server` · `T-SQL` · `Python` (pandas, matplotlib) · `Power BI` (modelo
dimensional, DAX) · `Git`

---

## Estructura del repositorio

```
analisis-retencion-isp/
├── generador_datos.py          Generación reproducible del dataset sintético
├── datos/
│   ├── raw/                    CSV de origen
│   └── processed/              Tabla analítica a nivel cliente
├── sql/
│   ├── 01_ddl_esquema.sql      Staging + modelo estrella + índices
│   ├── 02_carga_staging.sql    Carga masiva desde CSV
│   ├── 03_calidad_datos.sql    Controles de calidad cuantificados
│   ├── 04_transformacion.sql   Limpieza y carga al modelo final
│   └── 05_analisis.sql         Consultas de negocio
├── notebooks/
│   └── 01_limpieza_eda.ipynb   Análisis exploratorio y validación
├── powerbi/
│   ├── retencion_isp.pbix      Dashboard
│   └── capturas/
└── docs/
    ├── diccionario_datos.md
    └── informe_ejecutivo.pdf
```

---

## Cómo reproducirlo

```bash
# 1. Generar el dataset (opcional: ya está en datos/raw/)
python generador_datos.py

# 2. Crear el esquema
sqlcmd -S .\SQLEXPRESS -d retencion_isp -E -i sql/01_ddl_esquema.sql

# 3. Cargar los datos (editar antes la ruta en el script)
sqlcmd -S .\SQLEXPRESS -d retencion_isp -E -i sql/02_carga_staging.sql

# 4. Calidad, transformación y análisis
sqlcmd -S .\SQLEXPRESS -d retencion_isp -E -i sql/03_calidad_datos.sql
sqlcmd -S .\SQLEXPRESS -d retencion_isp -E -i sql/04_transformacion.sql
```

Requisitos: SQL Server 2019+, Python 3.10+ (`pandas`, `numpy`), Power BI Desktop.

---

## Autora

**[Martina Virgilli]** — [LinkedIn](https://www.linkedin.com/in/martina-virgilli-a80b95211/)

----------------------------------------------------

# Customer Retention Analysis for an ISP

> Identifying the drivers of customer churn at an internet service provider, and
> prioritising at-risk accounts for proactive retention.

<!-- ⬇ REPLACE with the dashboard screenshot once it's ready.
     Keep it above any text: it's the first thing a recruiter looks at, and
     often the only thing.
     Save it to powerbi/capturas/dashboard_resumen.png -->

![Retention dashboard](powerbi/capturas/dashboard_resumen.png)

**[View interactive dashboard](POWER_BI_SERVICE_URL)** · **[Executive summary (PDF)](docs/informe_ejecutivo.pdf)**

---

## Context

A telecommunications cooperative providing internet service along the Argentine
Atlantic coast lost a significant share of its customer base over the past 24
months. Management needs to understand why in order to decide where to invest:
is this a pricing problem, a competition problem, or a service quality problem?

**Business questions:**

1. What is the monthly churn rate, and how has it evolved?
2. Is churn concentrated in specific towns, plans, or customer segments?
3. What is the relationship between technical support tickets and churn?
4. What is the relationship between overdue payments and churn?
5. How much monthly recurring revenue was lost?
6. Which currently active customers are at risk and should be contacted first?

> **A note on the data:** this dataset is **synthetic**, generated with the
> [`generador_datos.py`](generador_datos.py) script included in this repository.
> It does not come from any real organisation. The business model, ticket
> categories, and seasonality patterns are modelled on how the industry
> typically operates.

---

## Data

Four tables covering 24 months of history (Aug 2024 – Jul 2026):

| Table | Records | Contents |
|---|---|---|
| `clientes` | 5,215 | Sign-up, cancellation, reason, plan, town, acquisition channel |
| `planes` | 6 | Plan catalogue and pricing |
| `facturacion` | 101,300 | Monthly billing, due dates, and collections |
| `tickets` | 31,341 | Support tickets: category, channel, priority, resolution, CSAT |

Full data dictionary in [`docs/diccionario_datos.md`](docs/diccionario_datos.md).

---

## Approach

| Phase | Tool | What was done |
|---|---|---|
| 1. Modelling & ingestion | SQL Server | Star schema with a staging layer; bulk load from CSV |
| 2. Data quality | SQL Server | 10 quantified quality checks against the staging layer |
| 3. Transformation | SQL Server | Cleaning, normalisation, and load into the final model |
| 4. Exploratory analysis | Python / pandas | Hypothesis testing and customer-level analytical table |
| 5. Visualisation | Power BI | Dimensional model, DAX measures, and a 3-page dashboard |

**Architecture decision:** data is first ingested into an untyped staging layer
and only transformed after quality issues have been measured. This makes it
possible to quantify how dirty the source is, rather than having the load fail
with no diagnosis.

---

## Data quality issues found

<!-- ⬇ FILL IN with the actual results from sql/03_calidad_datos.sql.
     This is the section recruiters value most and that almost nobody writes.
     The "Action taken" column matters most: spotting a problem is easy,
     justifying what you did about it is what demonstrates judgement. -->

| Issue | Records | % | Action taken |
|---|---|---|---|
| Exact duplicate rows in billing | | | |
| Tickets referencing non-existent customers | | | |
| Inconsistent `fecha_pago` date formats | | | |
| Negative amounts | | | |
| Data-entry errors in amounts (×100) | | | |
| `satisfaccion` outside the 1–5 range | | | |
| Spelling variants in `localidad` | | | |
| Spelling variants in `tipo_cliente` | | | |
| Missing contact details | | | |

**Methodological bias identified and corrected:**

<!-- ⬇ FILL IN. Explain the exposure bias: counting total tickets per customer
     means churned customers accumulate fewer tickets simply because they were
     active for fewer months, which inverts the true relationship. The fix was
     to measure within a fixed 90-day window before the end of the customer
     relationship. Write it up with your own numbers. -->

---

## Key findings

<!-- ⬇ FILL IN with 4–5 bullets, each carrying a number.
     Write the conclusion, not the description:
       BAD  → "The relationship between tickets and churn was analysed."
       GOOD → "Customers with 3+ technical tickets in 90 days churn at 56%,
               compared to 16% for everyone else." -->

1.
2.
3.
4.

---

## Recommendations

<!-- ⬇ FILL IN with 3 actionable recommendations, each with an estimated impact
     in revenue or customers retained. A recommendation without a number next
     to it is just an opinion. -->

1.
2.
3.

---

## Tech stack

`SQL Server` · `T-SQL` · `Python` (pandas, matplotlib) · `Power BI` (dimensional
modelling, DAX) · `Git`

---

## Repository structure

```
analisis-retencion-isp/
├── generador_datos.py          Reproducible synthetic dataset generation
├── datos/
│   ├── raw/                    Source CSV files
│   └── processed/              Customer-level analytical table
├── sql/
│   ├── 01_ddl_esquema.sql      Staging + star schema + indexes
│   ├── 02_carga_staging.sql    Bulk load from CSV
│   ├── 03_calidad_datos.sql    Quantified data quality checks
│   ├── 04_transformacion.sql   Cleaning and load into the final model
│   └── 05_analisis.sql         Business queries
├── notebooks/
│   └── 01_limpieza_eda.ipynb   Exploratory analysis and validation
├── powerbi/
│   ├── retencion_isp.pbix      Dashboard
│   └── capturas/
└── docs/
    ├── diccionario_datos.md
    └── informe_ejecutivo.pdf
```

> Note: file and column names are kept in Spanish throughout the codebase, as
> they would be in the original business context.

---

## How to reproduce

```bash
# 1. Generate the dataset (optional: already included in datos/raw/)
python generador_datos.py

# 2. Create the schema
sqlcmd -S .\SQLEXPRESS -d retencion_isp -E -i sql/01_ddl_esquema.sql

# 3. Load the data (update the file path inside the script first)
sqlcmd -S .\SQLEXPRESS -d retencion_isp -E -i sql/02_carga_staging.sql

# 4. Quality checks, transformation, and analysis
sqlcmd -S .\SQLEXPRESS -d retencion_isp -E -i sql/03_calidad_datos.sql
sqlcmd -S .\SQLEXPRESS -d retencion_isp -E -i sql/04_transformacion.sql
```

Requirements: SQL Server 2019+, Python 3.10+ (`pandas`, `numpy`), Power BI Desktop.

---

## Author

**[Martina Virgilli]** — [LinkedIn](https://www.linkedin.com/in/martina-virgilli-a80b95211/)
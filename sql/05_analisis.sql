/* ============================================================================
   PROYECTO : Análisis de Retención de Clientes en un ISP
   ARCHIVO  : 05_analisis.sql
   OBJETIVO : Responder las preguntas de negocio y construir la tabla analítica
              que alimenta la fase de Python y Power BI.
   REQUIERE : 04_transformacion.sql ejecutado.

   Ventana de datos: 2024-08-01 a 2026-07-31.
   ============================================================================ */

USE retencion_isp;
GO

-- Fecha de corte del análisis. Un cliente sin fecha_baja se considera activo
-- a esta fecha.
DECLARE @corte DATE = '2026-07-31';


/* ============================================================================
   P1 — KPIs generales
   ============================================================================ */

SELECT
    COUNT(*)                                                        AS clientes_totales,
    SUM(CASE WHEN fecha_baja IS NULL THEN 1 ELSE 0 END)             AS activos,
    SUM(CASE WHEN fecha_baja IS NOT NULL THEN 1 ELSE 0 END)         AS bajas,
    CAST(100.0 * SUM(CASE WHEN fecha_baja IS NOT NULL THEN 1 ELSE 0 END)
         / COUNT(*) AS DECIMAL(5,2))                                AS churn_acumulado_pct
FROM dbo.dim_cliente;
GO


/* ============================================================================
   P2 — Evolución mensual: activos, altas, bajas y churn
   ----------------------------------------------------------------------------
   El churn mensual se calcula sobre los clientes ACTIVOS AL INICIO del mes,
   no sobre el total de la base. Es la definición estándar del sector y la
   diferencia no es menor: usar el total subestima la tasa.
   ============================================================================ */

WITH meses AS (
    SELECT DISTINCT periodo AS mes FROM dbo.fact_facturacion
),
movimiento AS (
    SELECT
        m.mes,
        (SELECT COUNT(*) FROM dbo.dim_cliente AS c
          WHERE c.fecha_alta < m.mes
            AND (c.fecha_baja IS NULL OR c.fecha_baja >= m.mes))        AS activos_inicio,
        (SELECT COUNT(*) FROM dbo.dim_cliente AS c
          WHERE c.fecha_alta >= m.mes AND c.fecha_alta <= EOMONTH(m.mes)) AS altas,
        (SELECT COUNT(*) FROM dbo.dim_cliente AS c
          WHERE c.fecha_baja >= m.mes AND c.fecha_baja <= EOMONTH(m.mes)) AS bajas
    FROM meses AS m
)
SELECT
    mes,
    activos_inicio,
    altas,
    bajas,
    altas - bajas                                                       AS crecimiento_neto,
    CAST(100.0 * bajas / NULLIF(activos_inicio, 0) AS DECIMAL(5,2))     AS churn_pct,
    -- LAG permite comparar contra el mes anterior sin auto-join.
    CAST(100.0 * bajas / NULLIF(activos_inicio, 0)
         - LAG(CAST(100.0 * bajas / NULLIF(activos_inicio, 0) AS DECIMAL(5,2)))
           OVER (ORDER BY mes) AS DECIMAL(5,2))                         AS variacion_pp
FROM movimiento
ORDER BY mes;
GO


/* ============================================================================
   P3 — Churn por localidad
   Identifica si el problema es geográfico (infraestructura de red).
   ============================================================================ */

SELECT
    localidad,
    COUNT(*)                                                        AS clientes,
    SUM(CASE WHEN fecha_baja IS NOT NULL THEN 1 ELSE 0 END)         AS bajas,
    CAST(100.0 * SUM(CASE WHEN fecha_baja IS NOT NULL THEN 1 ELSE 0 END)
         / COUNT(*) AS DECIMAL(5,2))                                AS churn_pct
FROM dbo.dim_cliente
GROUP BY localidad
ORDER BY churn_pct DESC;
GO


/* ============================================================================
   P4 — Churn por plan y por tipo de cliente
   ============================================================================ */

SELECT
    p.nombre_plan,
    p.velocidad_mbps,
    p.precio_base,
    CAST(p.precio_base / p.velocidad_mbps AS DECIMAL(8,2))           AS precio_por_mbps,
    COUNT(*)                                                        AS clientes,
    CAST(100.0 * SUM(CASE WHEN c.fecha_baja IS NOT NULL THEN 1 ELSE 0 END)
         / COUNT(*) AS DECIMAL(5,2))                                AS churn_pct
FROM dbo.dim_cliente AS c
JOIN dbo.dim_plan AS p ON p.id_plan = c.id_plan
GROUP BY p.nombre_plan, p.velocidad_mbps, p.precio_base
ORDER BY churn_pct DESC;

SELECT
    tipo_cliente,
    COUNT(*)                                                        AS clientes,
    CAST(100.0 * SUM(CASE WHEN fecha_baja IS NOT NULL THEN 1 ELSE 0 END)
         / COUNT(*) AS DECIMAL(5,2))                                AS churn_pct
FROM dbo.dim_cliente
GROUP BY tipo_cliente;
GO


/* ============================================================================
   P5 — Cohortes de retención por mes de alta
   ----------------------------------------------------------------------------
   Agrupa a los clientes por el mes en que se dieron de alta y mide qué
   porcentaje sigue activo a los 3, 6 y 12 meses. Es la forma correcta de
   comparar antigüedades: una cohorte reciente no tuvo tiempo de churnear,
   así que compararla contra una vieja sin normalizar es un error.
   ============================================================================ */

WITH base AS (
    SELECT
        DATEFROMPARTS(YEAR(fecha_alta), MONTH(fecha_alta), 1)        AS cohorte,
        CASE WHEN fecha_baja IS NULL THEN NULL
             ELSE DATEDIFF(MONTH, fecha_alta, fecha_baja) END        AS meses_hasta_baja,
        DATEDIFF(MONTH, fecha_alta, '2026-07-31')                    AS meses_observados
    FROM dbo.dim_cliente
    WHERE fecha_alta >= '2024-08-01'
)
SELECT
    cohorte,
    COUNT(*)                                                        AS clientes,
    CAST(100.0 * SUM(CASE WHEN meses_hasta_baja IS NULL OR meses_hasta_baja >= 3
                          THEN 1 ELSE 0 END)
         / NULLIF(SUM(CASE WHEN meses_observados >= 3 THEN 1 ELSE 0 END), 0)
         AS DECIMAL(5,2))                                           AS retencion_3m_pct,
    CAST(100.0 * SUM(CASE WHEN meses_hasta_baja IS NULL OR meses_hasta_baja >= 6
                          THEN 1 ELSE 0 END)
         / NULLIF(SUM(CASE WHEN meses_observados >= 6 THEN 1 ELSE 0 END), 0)
         AS DECIMAL(5,2))                                           AS retencion_6m_pct,
    CAST(100.0 * SUM(CASE WHEN meses_hasta_baja IS NULL OR meses_hasta_baja >= 12
                          THEN 1 ELSE 0 END)
         / NULLIF(SUM(CASE WHEN meses_observados >= 12 THEN 1 ELSE 0 END), 0)
         AS DECIMAL(5,2))                                           AS retencion_12m_pct
FROM base
GROUP BY cohorte
ORDER BY cohorte;
GO


/* ============================================================================
   P6 — Reclamos técnicos vs. churn   ★ LA CONSULTA CENTRAL DEL PROYECTO
   ----------------------------------------------------------------------------
   SESGO DE EXPOSICIÓN — leer antes de modificar esta consulta:

   Si se contaran los tickets TOTALES por cliente, el resultado diría que más
   reclamos implica MENOS churn. Es falso: quien se dio de baja en el mes 3
   tuvo 3 meses para generar tickets, y quien sigue activo tuvo 24. El conteo
   total mide permanencia, no insatisfacción.

   La corrección es medir en una VENTANA FIJA de 90 días previos al fin de la
   relación (la baja, o la fecha de corte si sigue activo). Así todos los
   clientes se comparan sobre el mismo período de exposición.
   ============================================================================ */

WITH fin_relacion AS (
    SELECT
        c.id_cliente,
        c.fecha_baja,
        CASE WHEN c.fecha_baja IS NOT NULL THEN 1 ELSE 0 END         AS churn,
        COALESCE(c.fecha_baja, '2026-07-31')                         AS fecha_fin
    FROM dbo.dim_cliente AS c
),
tickets_ventana AS (
    SELECT
        f.id_cliente,
        f.churn,
        COUNT(t.id_ticket)                                           AS tickets_tec_90d
    FROM fin_relacion AS f
    LEFT JOIN dbo.fact_ticket AS t
           ON t.id_cliente = f.id_cliente
          AND t.es_tecnico = 1
          AND t.fecha_apertura <  DATEADD(DAY, 1, f.fecha_fin)
          AND t.fecha_apertura >= DATEADD(DAY, -90, f.fecha_fin)
    GROUP BY f.id_cliente, f.churn
)
SELECT
    CASE WHEN tickets_tec_90d = 0 THEN '0'
         WHEN tickets_tec_90d = 1 THEN '1'
         WHEN tickets_tec_90d = 2 THEN '2'
         ELSE '3+' END                                               AS tickets_tecnicos_90d,
    COUNT(*)                                                         AS clientes,
    SUM(churn)                                                       AS bajas,
    CAST(100.0 * SUM(churn) / COUNT(*) AS DECIMAL(5,2))              AS churn_pct
FROM tickets_ventana
GROUP BY CASE WHEN tickets_tec_90d = 0 THEN '0'
              WHEN tickets_tec_90d = 1 THEN '1'
              WHEN tickets_tec_90d = 2 THEN '2'
              ELSE '3+' END
ORDER BY tickets_tecnicos_90d;
GO


/* ============================================================================
   P7 — Morosidad vs. churn
   Misma lógica de ventana fija: 4 períodos de facturación previos al fin.
   ============================================================================ */

WITH fin_relacion AS (
    SELECT
        c.id_cliente,
        CASE WHEN c.fecha_baja IS NOT NULL THEN 1 ELSE 0 END         AS churn,
        COALESCE(c.fecha_baja, '2026-07-31')                         AS fecha_fin
    FROM dbo.dim_cliente AS c
),
impagas AS (
    SELECT
        f.id_cliente,
        f.churn,
        COUNT(fa.id_factura)                                         AS impagas_4m
    FROM fin_relacion AS f
    LEFT JOIN dbo.fact_facturacion AS fa
           ON fa.id_cliente = f.id_cliente
          AND fa.fecha_pago IS NULL
          AND fa.periodo <= f.fecha_fin
          AND fa.periodo >  DATEADD(MONTH, -4, f.fecha_fin)
    GROUP BY f.id_cliente, f.churn
)
SELECT
    CASE WHEN impagas_4m = 0 THEN '0'
         WHEN impagas_4m = 1 THEN '1'
         WHEN impagas_4m = 2 THEN '2'
         ELSE '3+' END                                               AS facturas_impagas_4m,
    COUNT(*)                                                         AS clientes,
    SUM(churn)                                                       AS bajas,
    CAST(100.0 * SUM(churn) / COUNT(*) AS DECIMAL(5,2))              AS churn_pct
FROM impagas
GROUP BY CASE WHEN impagas_4m = 0 THEN '0'
              WHEN impagas_4m = 1 THEN '1'
              WHEN impagas_4m = 2 THEN '2'
              ELSE '3+' END
ORDER BY facturas_impagas_4m;
GO


/* ============================================================================
   P8 — Calidad de servicio: MTTR y CSAT
   ----------------------------------------------------------------------------
   MTTR se calcula solo sobre tickets CERRADOS: incluir los abiertos con
   duración nula subestimaría el tiempo real de resolución.
   ============================================================================ */

SELECT
    DATEFROMPARTS(YEAR(fecha_apertura), MONTH(fecha_apertura), 1)    AS mes,
    COUNT(*)                                                         AS tickets,
    SUM(CAST(es_tecnico AS INT))                                     AS tickets_tecnicos,
    CAST(AVG(CASE WHEN fecha_cierre IS NOT NULL
                  THEN DATEDIFF(HOUR, fecha_apertura, fecha_cierre) * 1.0 END)
         AS DECIMAL(8,1))                                            AS mttr_horas,
    CAST(AVG(CAST(satisfaccion AS DECIMAL(4,2))) AS DECIMAL(4,2))    AS csat,
    SUM(CASE WHEN fecha_cierre IS NULL THEN 1 ELSE 0 END)            AS abiertos
FROM dbo.fact_ticket
GROUP BY DATEFROMPARTS(YEAR(fecha_apertura), MONTH(fecha_apertura), 1)
ORDER BY mes;

-- MTTR y CSAT por categoría: dónde se concentra el problema operativo.
SELECT
    categoria,
    COUNT(*)                                                         AS tickets,
    CAST(AVG(CASE WHEN fecha_cierre IS NOT NULL
                  THEN DATEDIFF(HOUR, fecha_apertura, fecha_cierre) * 1.0 END)
         AS DECIMAL(8,1))                                            AS mttr_horas,
    CAST(AVG(CAST(satisfaccion AS DECIMAL(4,2))) AS DECIMAL(4,2))    AS csat
FROM dbo.fact_ticket
GROUP BY categoria
ORDER BY mttr_horas DESC;
GO


/* ============================================================================
   P9 — Ingresos, cobranza y MRR perdido
   ============================================================================ */

SELECT
    periodo,
    COUNT(*)                                                         AS facturas,
    CAST(SUM(monto) AS DECIMAL(16,2))                                AS facturado,
    CAST(SUM(CASE WHEN fecha_pago IS NOT NULL THEN monto ELSE 0 END)
         AS DECIMAL(16,2))                                           AS cobrado,
    CAST(100.0 * SUM(CASE WHEN fecha_pago IS NULL THEN monto ELSE 0 END)
         / NULLIF(SUM(monto), 0) AS DECIMAL(5,2))                    AS morosidad_pct,
    CAST(SUM(monto) / COUNT(DISTINCT id_cliente) AS DECIMAL(12,2))   AS arpu,
    -- Días promedio de atraso sobre lo efectivamente cobrado.
    CAST(AVG(CASE WHEN fecha_pago IS NOT NULL
                  THEN DATEDIFF(DAY, fecha_vencimiento, fecha_pago) * 1.0 END)
         AS DECIMAL(6,1))                                            AS dias_atraso_prom
FROM dbo.fact_facturacion
GROUP BY periodo
ORDER BY periodo;

-- MRR perdido: ingreso mensual que representaban los clientes dados de baja.
WITH ultima_factura AS (
    SELECT
        f.id_cliente,
        f.monto,
        ROW_NUMBER() OVER (PARTITION BY f.id_cliente ORDER BY f.periodo DESC) AS rn
    FROM dbo.fact_facturacion AS f
)
SELECT
    DATEFROMPARTS(YEAR(c.fecha_baja), MONTH(c.fecha_baja), 1)        AS mes_baja,
    COUNT(*)                                                         AS bajas,
    CAST(SUM(u.monto) AS DECIMAL(16,2))                              AS mrr_perdido
FROM dbo.dim_cliente AS c
JOIN ultima_factura AS u ON u.id_cliente = c.id_cliente AND u.rn = 1
WHERE c.fecha_baja IS NOT NULL
GROUP BY DATEFROMPARTS(YEAR(c.fecha_baja), MONTH(c.fecha_baja), 1)
ORDER BY mes_baja;
GO


/* ============================================================================
   P10 — Motivos declarados de baja
   Contrastar con los hallazgos de P6 y P7: el motivo declarado y la causa
   observable no siempre coinciden, y esa brecha es un hallazgo en sí misma.
   ============================================================================ */

SELECT
    motivo_baja,
    COUNT(*)                                                         AS bajas,
    CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS DECIMAL(5,2))   AS pct
FROM dbo.dim_cliente
WHERE fecha_baja IS NOT NULL
GROUP BY motivo_baja
ORDER BY bajas DESC;
GO


/* ============================================================================
   TABLA ANALÍTICA — una fila por cliente
   ----------------------------------------------------------------------------
   Es el entregable que alimenta la fase de Python (EDA y validación) y el
   modelo de Power BI. Consolida las variables construidas arriba.

   Exportar después a datos/processed/tabla_analitica.csv:
     SSMS -> click derecho sobre la grilla -> Save Results As... -> CSV
     (o botón derecho sobre la base -> Tasks -> Export Data)
   ============================================================================ */

DROP TABLE IF EXISTS dbo.analitica_cliente;
GO

WITH fin_relacion AS (
    SELECT
        c.id_cliente,
        COALESCE(c.fecha_baja, '2026-07-31')                         AS fecha_fin
    FROM dbo.dim_cliente AS c
),
agg_tickets AS (
    SELECT
        f.id_cliente,
        COUNT(t.id_ticket)                                           AS tickets_total,
        SUM(CASE WHEN t.es_tecnico = 1 THEN 1 ELSE 0 END)            AS tickets_tecnicos_total,
        SUM(CASE WHEN t.es_tecnico = 1
                  AND t.fecha_apertura >= DATEADD(DAY, -90, f.fecha_fin)
                 THEN 1 ELSE 0 END)                                  AS tickets_tecnicos_90d,
        AVG(CASE WHEN t.fecha_cierre IS NOT NULL
                 THEN DATEDIFF(HOUR, t.fecha_apertura, t.fecha_cierre) * 1.0 END) AS mttr_horas,
        AVG(CAST(t.satisfaccion AS DECIMAL(4,2)))                    AS csat
    FROM fin_relacion AS f
    LEFT JOIN dbo.fact_ticket AS t
           ON t.id_cliente = f.id_cliente
          AND t.fecha_apertura < DATEADD(DAY, 1, f.fecha_fin)
    GROUP BY f.id_cliente
),
agg_facturacion AS (
    SELECT
        f.id_cliente,
        COUNT(fa.id_factura)                                         AS facturas_total,
        SUM(CASE WHEN fa.fecha_pago IS NULL THEN 1 ELSE 0 END)       AS impagas_total,
        SUM(CASE WHEN fa.fecha_pago IS NULL
                  AND fa.periodo > DATEADD(MONTH, -4, f.fecha_fin)
                 THEN 1 ELSE 0 END)                                  AS impagas_4m,
        AVG(fa.monto)                                                AS monto_promedio,
        MAX(fa.monto)                                                AS ingreso_mensual
    FROM fin_relacion AS f
    LEFT JOIN dbo.fact_facturacion AS fa
           ON fa.id_cliente = f.id_cliente
          AND fa.periodo <= f.fecha_fin
    GROUP BY f.id_cliente
)
SELECT
    c.id_cliente,
    c.tipo_cliente,
    c.localidad,
    p.nombre_plan,
    p.velocidad_mbps,
    p.precio_base,
    c.canal_alta,
    c.fecha_alta,
    c.fecha_baja,
    c.motivo_baja,
    CASE WHEN c.fecha_baja IS NOT NULL THEN 1 ELSE 0 END             AS churn,
    DATEDIFF(MONTH, c.fecha_alta, COALESCE(c.fecha_baja, '2026-07-31')) AS antiguedad_meses,
    ISNULL(t.tickets_total, 0)                                       AS tickets_total,
    ISNULL(t.tickets_tecnicos_total, 0)                              AS tickets_tecnicos_total,
    ISNULL(t.tickets_tecnicos_90d, 0)                                AS tickets_tecnicos_90d,
    CAST(t.mttr_horas AS DECIMAL(8,1))                               AS mttr_horas,
    CAST(t.csat AS DECIMAL(4,2))                                     AS csat,
    ISNULL(fa.facturas_total, 0)                                     AS facturas_total,
    ISNULL(fa.impagas_total, 0)                                      AS impagas_total,
    ISNULL(fa.impagas_4m, 0)                                         AS impagas_4m,
    CAST(fa.monto_promedio AS DECIMAL(12,2))                         AS monto_promedio,
    CAST(fa.ingreso_mensual AS DECIMAL(12,2))                        AS ingreso_mensual
INTO dbo.analitica_cliente
FROM dbo.dim_cliente AS c
JOIN dbo.dim_plan AS p        ON p.id_plan    = c.id_plan
LEFT JOIN agg_tickets AS t     ON t.id_cliente = c.id_cliente
LEFT JOIN agg_facturacion AS fa ON fa.id_cliente = c.id_cliente;
GO

SELECT COUNT(*) AS filas_tabla_analitica FROM dbo.analitica_cliente;  -- esperado: 5215
SELECT TOP 20 * FROM dbo.analitica_cliente ORDER BY id_cliente;
GO

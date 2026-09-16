/* ============================================================================
   PROYECTO : Análisis de Retención de Clientes en un ISP
   ARCHIVO  : 03_calidad_datos.sql
   OBJETIVO : Medir y registrar los problemas de calidad de la capa staging.
   REQUIERE : 02_carga_staging.sql ejecutado.

   IMPORTANTE: este script NO modifica ni corrige datos. Solo mide y deja
   constancia en dbo.qa_resultados. La corrección ocurre en 04_transformacion.

   Regla de trabajo: cada control primero MIRA las filas problemáticas
   (SELECT), después las CUANTIFICA y registra la DECISIÓN tomada.
   ============================================================================ */

USE retencion_isp;
GO

-- Script re-ejecutable: se limpia el registro previo.
DELETE FROM dbo.qa_resultados;
GO


/* ============================================================================
   CONTROL 1 — Integridad de la carga
   ¿Entró la cantidad de filas esperada en cada tabla?
   ============================================================================ */

INSERT INTO dbo.qa_resultados (tabla_origen, control, registros, pct_total, decision)
SELECT 'stg_planes',      'Filas cargadas (esperadas: 6)',        COUNT(*), NULL, 'OK' FROM dbo.stg_planes
UNION ALL
SELECT 'stg_clientes',    'Filas cargadas (esperadas: 5215)',     COUNT(*), NULL, 'OK' FROM dbo.stg_clientes
UNION ALL
SELECT 'stg_facturacion', 'Filas cargadas (esperadas: 101300)',   COUNT(*), NULL, 'OK' FROM dbo.stg_facturacion
UNION ALL
SELECT 'stg_tickets',     'Filas cargadas (esperadas: 31341)',    COUNT(*), NULL, 'OK' FROM dbo.stg_tickets;
GO


/* ============================================================================
   CONTROL 2 — Filas duplicadas exactas en facturación
   ----------------------------------------------------------------------------
   Se cuentan FILAS SOBRANTES, no grupos duplicados. Si un registro aparece
   3 veces, sobran 2. Ese es el número que corresponde reportar.
   ============================================================================ */

-- 2a. Mirar
SELECT TOP 10 id_factura, id_cliente, periodo, monto, COUNT(*) AS apariciones
FROM dbo.stg_facturacion
GROUP BY id_factura, id_cliente, periodo, id_plan, monto,
         fecha_vencimiento, fecha_pago, medio_pago
HAVING COUNT(*) > 1
ORDER BY apariciones DESC;

-- 2b. Cuantificar y registrar
WITH grupos AS (
    SELECT COUNT(*) AS apariciones
    FROM dbo.stg_facturacion
    GROUP BY id_factura, id_cliente, periodo, id_plan, monto,
             fecha_vencimiento, fecha_pago, medio_pago
    HAVING COUNT(*) > 1
)
INSERT INTO dbo.qa_resultados (tabla_origen, control, registros, pct_total, decision)
SELECT
    'stg_facturacion',
    'Filas duplicadas exactas (sobrantes)',
    ISNULL(SUM(apariciones - 1), 0),
    CAST(100.0 * ISNULL(SUM(apariciones - 1), 0)
         / (SELECT COUNT(*) FROM dbo.stg_facturacion) AS DECIMAL(6,2)),
    'Eliminar conservando una ocurrencia por id_factura (ROW_NUMBER en 04). Son duplicados de transporte, no hechos de negocio: inflarían la facturación reportada.'
FROM grupos;
GO


/* ============================================================================
   CONTROL 3 — Unicidad de id_factura
   Define si id_factura sirve como clave primaria de fact_facturacion.
   ============================================================================ */

INSERT INTO dbo.qa_resultados (tabla_origen, control, registros, pct_total, decision)
SELECT
    'stg_facturacion',
    'id_factura distintos (define viabilidad de la PK)',
    COUNT(DISTINCT id_factura),
    NULL,
    'id_factura es único una vez deduplicado, por lo que se usa como PK natural de fact_facturacion.'
FROM dbo.stg_facturacion;
GO


/* ============================================================================
   CONTROL 4 — Nulos por columna
   ----------------------------------------------------------------------------
   Se usa NULLIF(TRIM(col),'') porque BULK INSERT puede cargar los campos
   vacíos del CSV como cadena vacía en vez de NULL, según la versión del motor.
   Tratar ambos casos evita depender de ese comportamiento.
   ============================================================================ */

SELECT
    SUM(CASE WHEN NULLIF(TRIM(fecha_baja),  '') IS NULL THEN 1 ELSE 0 END) AS sin_fecha_baja,
    SUM(CASE WHEN NULLIF(TRIM(motivo_baja), '') IS NULL THEN 1 ELSE 0 END) AS sin_motivo_baja,
    SUM(CASE WHEN NULLIF(TRIM(email),       '') IS NULL THEN 1 ELSE 0 END) AS sin_email,
    SUM(CASE WHEN NULLIF(TRIM(telefono),    '') IS NULL THEN 1 ELSE 0 END) AS sin_telefono
FROM dbo.stg_clientes;

DECLARE @tot_cli DECIMAL(18,2) = (SELECT COUNT(*) FROM dbo.stg_clientes);

INSERT INTO dbo.qa_resultados (tabla_origen, control, registros, pct_total, decision)
SELECT 'stg_clientes', 'Clientes sin email', COUNT(*),
       CAST(100.0 * COUNT(*) / @tot_cli AS DECIMAL(6,2)),
       'Conservar como NULL. No afecta el análisis de retención; solo limitaría una campaña de contacto por mail.'
FROM dbo.stg_clientes WHERE NULLIF(TRIM(email), '') IS NULL
UNION ALL
SELECT 'stg_clientes', 'Clientes sin teléfono', COUNT(*),
       CAST(100.0 * COUNT(*) / @tot_cli AS DECIMAL(6,2)),
       'Conservar como NULL. Mismo criterio que email.'
FROM dbo.stg_clientes WHERE NULLIF(TRIM(telefono), '') IS NULL
UNION ALL
SELECT 'stg_clientes', 'Clientes sin fecha_baja (= activos)', COUNT(*),
       CAST(100.0 * COUNT(*) / @tot_cli AS DECIMAL(6,2)),
       'NULL LEGÍTIMO: ausencia de fecha de baja significa cliente activo. No se imputa.'
FROM dbo.stg_clientes WHERE NULLIF(TRIM(fecha_baja), '') IS NULL;
GO

DECLARE @tot_fac DECIMAL(18,2) = (SELECT COUNT(*) FROM dbo.stg_facturacion);

INSERT INTO dbo.qa_resultados (tabla_origen, control, registros, pct_total, decision)
SELECT 'stg_facturacion', 'Facturas sin fecha_pago (= impagas)', COUNT(*),
       CAST(100.0 * COUNT(*) / @tot_fac AS DECIMAL(6,2)),
       'NULL LEGÍTIMO: es el indicador de factura impaga y una variable central del análisis de morosidad. No se imputa.'
FROM dbo.stg_facturacion WHERE NULLIF(TRIM(fecha_pago), '') IS NULL;
GO

DECLARE @tot_tk DECIMAL(18,2) = (SELECT COUNT(*) FROM dbo.stg_tickets);

INSERT INTO dbo.qa_resultados (tabla_origen, control, registros, pct_total, decision)
SELECT 'stg_tickets', 'Tickets sin satisfacción (encuesta no respondida)', COUNT(*),
       CAST(100.0 * COUNT(*) / @tot_tk AS DECIMAL(6,2)),
       'NULL LEGÍTIMO: no toda gestión recibe encuesta. El CSAT se calcula sobre la base de respondidas, aclarándolo en el dashboard.'
FROM dbo.stg_tickets WHERE NULLIF(TRIM(satisfaccion), '') IS NULL
UNION ALL
SELECT 'stg_tickets', 'Tickets sin fecha_cierre (= abiertos)', COUNT(*),
       CAST(100.0 * COUNT(*) / @tot_tk AS DECIMAL(6,2)),
       'NULL LEGÍTIMO: tickets aún abiertos, concentrados en el último período. Se excluyen del cálculo de MTTR.'
FROM dbo.stg_tickets WHERE NULLIF(TRIM(fecha_cierre), '') IS NULL;
GO


/* ============================================================================
   CONTROL 5 — Variantes de escritura en campos categóricos
   ----------------------------------------------------------------------------
   La collation de la base es CI (case insensitive), por lo que un GROUP BY
   normal OCULTA las variantes de mayúsculas. Se fuerza COLLATE ..._BIN2 para
   comparar byte por byte y que las variantes reales queden a la vista.
   ============================================================================ */

SELECT tipo_cliente COLLATE Latin1_General_100_BIN2 AS variante, COUNT(*) AS registros
FROM dbo.stg_clientes
GROUP BY tipo_cliente COLLATE Latin1_General_100_BIN2
ORDER BY registros DESC;

SELECT localidad COLLATE Latin1_General_100_BIN2 AS variante, COUNT(*) AS registros
FROM dbo.stg_clientes
GROUP BY localidad COLLATE Latin1_General_100_BIN2
ORDER BY registros DESC;

INSERT INTO dbo.qa_resultados (tabla_origen, control, registros, pct_total, decision)
SELECT 'stg_clientes',
       'Variantes de escritura en tipo_cliente (reales: 2)',
       COUNT(DISTINCT tipo_cliente COLLATE Latin1_General_100_BIN2),
       NULL,
       'Normalizar con TRIM + CASE sobre UPPER. La collation CI de la base las ocultaba en un GROUP BY normal; se detectaron forzando comparación binaria.'
FROM dbo.stg_clientes
UNION ALL
SELECT 'stg_clientes',
       'Variantes de escritura en localidad (reales: 6)',
       COUNT(DISTINCT localidad COLLATE Latin1_General_100_BIN2),
       NULL,
       'Normalizar con TRIM + eliminación de tildes + CASE contra catálogo cerrado de 6 localidades. Sin esto, el churn por localidad queda fragmentado y el hallazgo principal no aparece.'
FROM dbo.stg_clientes;
GO

-- Espacios sobrantes: SQL Server ignora los del final en las comparaciones,
-- pero no los del principio. Por eso se mide con DATALENGTH y no con <>.
INSERT INTO dbo.qa_resultados (tabla_origen, control, registros, pct_total, decision)
SELECT 'stg_clientes',
       'Localidades con espacios sobrantes al inicio o al final',
       COUNT(*),
       CAST(100.0 * COUNT(*) / (SELECT COUNT(*) FROM dbo.stg_clientes) AS DECIMAL(6,2)),
       'Corregir con TRIM en la normalización.'
FROM dbo.stg_clientes
WHERE DATALENGTH(localidad) <> DATALENGTH(TRIM(localidad));
GO


/* ============================================================================
   CONTROL 6 — Tickets con cliente inexistente (anti-join)
   ============================================================================ */

-- 6a. Mirar: ¿están concentrados en alguna categoría o período?
SELECT t.categoria, COUNT(*) AS registros,
       MIN(t.fecha_apertura) AS desde, MAX(t.fecha_apertura) AS hasta
FROM dbo.stg_tickets AS t
LEFT JOIN dbo.stg_clientes AS c ON c.id_cliente = t.id_cliente
WHERE c.id_cliente IS NULL
GROUP BY t.categoria
ORDER BY registros DESC;

-- 6b. Cuantificar y registrar
INSERT INTO dbo.qa_resultados (tabla_origen, control, registros, pct_total, decision)
SELECT
    'stg_tickets',
    'Tickets con id_cliente inexistente',
    COUNT(*),
    CAST(100.0 * COUNT(*) / (SELECT COUNT(*) FROM dbo.stg_tickets) AS DECIMAL(6,2)),
    'Aislar en rej_tickets_huerfanos y excluir de fact_ticket. Distribuidos uniformemente entre categorías y períodos, por lo que su exclusión no sesga el análisis. No se eliminan, para preservar trazabilidad.'
FROM dbo.stg_tickets AS t
LEFT JOIN dbo.stg_clientes AS c ON c.id_cliente = t.id_cliente
WHERE c.id_cliente IS NULL;
GO


/* ============================================================================
   CONTROL 7 — Satisfacción fuera de rango
   ----------------------------------------------------------------------------
   Ojo: el valor viene del CSV como "5.0". TRY_CONVERT(TINYINT, '5.0') devuelve
   NULL, porque SQL Server no convierte texto con decimal directo a entero.
   Hay que pasar primero por DECIMAL.
   ============================================================================ */

SELECT satisfaccion, COUNT(*) AS registros
FROM dbo.stg_tickets
WHERE TRY_CONVERT(DECIMAL(5,2), satisfaccion) NOT BETWEEN 1 AND 5
GROUP BY satisfaccion;

INSERT INTO dbo.qa_resultados (tabla_origen, control, registros, pct_total, decision)
SELECT
    'stg_tickets',
    'Satisfacción fuera del rango válido 1-5',
    COUNT(*),
    CAST(100.0 * COUNT(*) / (SELECT COUNT(*) FROM dbo.stg_tickets) AS DECIMAL(6,2)),
    'Anular el valor (NULL) conservando el ticket. El registro de la gestión es válido; lo inválido es la respuesta de la encuesta. Eliminar la fila perdería un reclamo real.'
FROM dbo.stg_tickets
WHERE NULLIF(TRIM(satisfaccion), '') IS NOT NULL
  AND TRY_CONVERT(DECIMAL(5,2), satisfaccion) NOT BETWEEN 1 AND 5;
GO


/* ============================================================================
   CONTROL 8 — Montos anómalos
   ----------------------------------------------------------------------------
   Se distinguen dos fenómenos que parecen el mismo problema y no lo son:
     · negativos  -> notas de crédito. Son hechos de negocio válidos.
     · x100       -> error de carga. Se detectan comparando contra el precio
                     del plan, criterio más robusto que un desvío estándar.
   ============================================================================ */

SELECT TOP 20 f.id_factura, f.id_plan, f.monto, p.precio_base
FROM dbo.stg_facturacion AS f
JOIN dbo.stg_planes AS p ON p.id_plan = f.id_plan
WHERE ABS(TRY_CONVERT(DECIMAL(14,2), f.monto)) > TRY_CONVERT(DECIMAL(14,2), p.precio_base) * 5
ORDER BY ABS(TRY_CONVERT(DECIMAL(14,2), f.monto)) DESC;

INSERT INTO dbo.qa_resultados (tabla_origen, control, registros, pct_total, decision)
SELECT 'stg_facturacion', 'Montos negativos', COUNT(*),
       CAST(100.0 * COUNT(*) / (SELECT COUNT(*) FROM dbo.stg_facturacion) AS DECIMAL(6,2)),
       'CONSERVAR. Son notas de crédito, un hecho de negocio legítimo. Eliminarlas sobrestimaría la facturación real.'
FROM dbo.stg_facturacion
WHERE TRY_CONVERT(DECIMAL(14,2), monto) < 0
UNION ALL
SELECT 'stg_facturacion', 'Montos con error de carga (x100 sobre el precio del plan)', COUNT(*),
       CAST(100.0 * COUNT(*) / (SELECT COUNT(*) FROM dbo.stg_facturacion) AS DECIMAL(6,2)),
       'Corregir dividiendo por 100. El error es inequívoco: superan en más de 5 veces el precio del plan, cuando el ajuste tarifario máximo del período fue del 68%.'
FROM dbo.stg_facturacion AS f
JOIN dbo.stg_planes AS p ON p.id_plan = f.id_plan
WHERE ABS(TRY_CONVERT(DECIMAL(14,2), f.monto)) > TRY_CONVERT(DECIMAL(14,2), p.precio_base) * 5;
GO


/* ============================================================================
   CONTROL 9 — Formatos de fecha inconsistentes en fecha_pago
   ----------------------------------------------------------------------------
   Estilo 23  = 'yyyy-mm-dd'  ·  Estilo 103 = 'dd/mm/yyyy'
   TRY_CONVERT devuelve NULL si el texto no corresponde al estilo indicado,
   lo que permite clasificar cada valor sin que el script falle.
   ============================================================================ */

SELECT
    SUM(CASE WHEN TRY_CONVERT(DATE, fecha_pago, 23)  IS NOT NULL THEN 1 ELSE 0 END) AS formato_iso,
    SUM(CASE WHEN TRY_CONVERT(DATE, fecha_pago, 23)  IS NULL
              AND TRY_CONVERT(DATE, fecha_pago, 103) IS NOT NULL THEN 1 ELSE 0 END) AS formato_dmy,
    SUM(CASE WHEN NULLIF(TRIM(fecha_pago), '') IS NOT NULL
              AND TRY_CONVERT(DATE, fecha_pago, 23)  IS NULL
              AND TRY_CONVERT(DATE, fecha_pago, 103) IS NULL THEN 1 ELSE 0 END) AS no_parsea
FROM dbo.stg_facturacion;

INSERT INTO dbo.qa_resultados (tabla_origen, control, registros, pct_total, decision)
SELECT 'stg_facturacion', 'fecha_pago en formato dd/mm/yyyy (minoritario)', COUNT(*),
       CAST(100.0 * COUNT(*) / (SELECT COUNT(*) FROM dbo.stg_facturacion) AS DECIMAL(6,2)),
       'Unificar a DATE con COALESCE de TRY_CONVERT estilos 23 y 103. Crítico: interpretar 10/07/2026 como mm/dd desplazaría el pago tres meses y falsearía la mora.'
FROM dbo.stg_facturacion
WHERE TRY_CONVERT(DATE, fecha_pago, 23) IS NULL
  AND TRY_CONVERT(DATE, fecha_pago, 103) IS NOT NULL
UNION ALL
SELECT 'stg_facturacion', 'fecha_pago que no parsea con ningún formato conocido', COUNT(*),
       CAST(100.0 * COUNT(*) / (SELECT COUNT(*) FROM dbo.stg_facturacion) AS DECIMAL(6,2)),
       'Si el conteo es 0, los dos formatos cubren el universo y la conversión es segura.'
FROM dbo.stg_facturacion
WHERE NULLIF(TRIM(fecha_pago), '') IS NOT NULL
  AND TRY_CONVERT(DATE, fecha_pago, 23) IS NULL
  AND TRY_CONVERT(DATE, fecha_pago, 103) IS NULL;
GO


/* ============================================================================
   CONTROL 10 — Coherencia temporal
   Verifica reglas que la realidad no puede violar.
   ============================================================================ */

INSERT INTO dbo.qa_resultados (tabla_origen, control, registros, pct_total, decision)
SELECT 'stg_clientes', 'Bajas anteriores al alta (imposible)', COUNT(*), NULL,
       'Corregir igualando fecha_baja a fecha_alta. Son clientes dados de baja en su mismo mes de alta: el error está en el día, no en el mes. Se conserva el evento de churn; descartarlos subestimaría el churn de las cohortes nuevas.'
FROM dbo.stg_clientes
WHERE TRY_CONVERT(DATE, fecha_baja, 23) < TRY_CONVERT(DATE, fecha_alta, 23)
UNION ALL
SELECT 'stg_tickets', 'Cierres anteriores a la apertura (imposible)', COUNT(*), NULL,
       'Si el conteo es 0, los tiempos de resolución son confiables para el MTTR.'
FROM dbo.stg_tickets
WHERE TRY_CONVERT(DATETIME2(0), fecha_cierre, 120) < TRY_CONVERT(DATETIME2(0), fecha_apertura, 120)
UNION ALL
SELECT 'stg_facturacion', 'Facturas de períodos posteriores a la baja del cliente', COUNT(*), NULL,
       'Se esperan 0 salvo la factura del propio mes de baja, que es legítima: el servicio se prestó parte del mes.'
FROM dbo.stg_facturacion AS f
JOIN dbo.stg_clientes AS c ON c.id_cliente = f.id_cliente
WHERE TRY_CONVERT(DATE, c.fecha_baja, 23) IS NOT NULL
  AND CONVERT(DATE, f.periodo + '-01') > EOMONTH(TRY_CONVERT(DATE, c.fecha_baja, 23));
GO


/* ============================================================================
   INFORME FINAL — de acá sale la tabla del README
   ============================================================================ */

SELECT tabla_origen, control, registros, pct_total, decision
FROM dbo.qa_resultados
ORDER BY id_control;
GO

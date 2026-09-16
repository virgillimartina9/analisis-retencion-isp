/* ============================================================================
   PROYECTO : Análisis de Retención de Clientes en un ISP
   ARCHIVO  : 04_transformacion.sql
   OBJETIVO : Aplicar las decisiones registradas en qa_resultados y cargar el
              modelo final (dim_plan, dim_cliente, fact_facturacion, fact_ticket).
   REQUIERE : 03_calidad_datos.sql ejecutado.

   Script re-ejecutable. Vacía las tablas finales respetando el orden de las
   claves foráneas (hechos primero, dimensiones después).

   Las restricciones definidas en 01 actúan como red de seguridad: si alguna
   limpieza quedara incompleta, el INSERT falla en vez de admitir datos sucios.
   ============================================================================ */

USE retencion_isp;
GO

DELETE FROM dbo.fact_facturacion;
DELETE FROM dbo.fact_ticket;
DELETE FROM dbo.dim_cliente;
DELETE FROM dbo.dim_plan;
GO


/* ============================================================================
   1. TABLAS DE RECHAZO (cuarentena)
   ----------------------------------------------------------------------------
   Los registros que no pueden entrar al modelo no se borran: se apartan. Es el
   patrón estándar de cualquier ETL serio y permite responder después qué pasó
   con ellos.
   ============================================================================ */

DROP TABLE IF EXISTS dbo.rej_tickets_huerfanos;
GO

SELECT t.*
INTO dbo.rej_tickets_huerfanos
FROM dbo.stg_tickets AS t
LEFT JOIN dbo.stg_clientes AS c ON c.id_cliente = t.id_cliente
WHERE c.id_cliente IS NULL;
GO


/* ============================================================================
   2. dim_plan
   Catálogo limpio en origen: solo se castean los tipos.
   ============================================================================ */

INSERT INTO dbo.dim_plan (id_plan, nombre_plan, tipo_plan, velocidad_mbps, precio_base)
SELECT
    TRIM(id_plan),
    TRIM(nombre_plan),
    TRIM(tipo_plan),
    CONVERT(INT, TRIM(velocidad_mbps)),
    CONVERT(DECIMAL(12,2), TRIM(precio_base))
FROM dbo.stg_planes;
GO


/* ============================================================================
   3. dim_cliente
   ----------------------------------------------------------------------------
   Normalizaciones aplicadas:
     · tipo_cliente -> TRIM + CASE sobre UPPER (6 variantes -> 2 valores)
     · localidad    -> TRIM + eliminación de tildes + CASE contra catálogo
                       cerrado (25 variantes -> 6 valores)
     · contacto     -> cadena vacía convertida a NULL
     · baja         -> fecha y motivo se mantienen coherentes entre sí

   Sobre las tildes: se reemplazan explícitamente en vez de usar una collation
   accent-insensitive, para que el resultado no dependa de la configuración de
   la base y el script sea portable.
   ============================================================================ */

INSERT INTO dbo.dim_cliente
    (id_cliente, tipo_cliente, localidad, id_plan, fecha_alta,
     fecha_baja, motivo_baja, canal_alta, email, telefono)
SELECT
    TRIM(c.id_cliente),

    CASE UPPER(TRIM(c.tipo_cliente))
        WHEN 'RESIDENCIAL' THEN 'Residencial'
        WHEN 'COMERCIAL'   THEN 'Comercial'
    END,

    CASE REPLACE(REPLACE(UPPER(TRIM(c.localidad)), 'Í', 'I'), 'Ó', 'O')
        WHEN 'PINAMAR'           THEN 'Pinamar'
        WHEN 'OSTENDE'           THEN 'Ostende'
        WHEN 'VALERIA DEL MAR'   THEN 'Valeria del Mar'
        WHEN 'CARILO'            THEN 'Cariló'
        WHEN 'MAR DE OSTENDE'    THEN 'Mar de Ostende'
        WHEN 'GENERAL MADARIAGA' THEN 'General Madariaga'
    END,

    TRIM(c.id_plan),
    CONVERT(DATE, TRIM(c.fecha_alta), 23),

    -- 6 clientes tienen fecha_baja anterior a fecha_alta, todos dados de baja
    -- en su mismo mes de alta: el error está en el día, no en el mes. Se
    -- iguala la baja al alta (baja el día del alta) para preservar el evento
    -- de churn sin violar CK_dim_cliente_fechas. Descartarlos subestimaría el
    -- churn de las cohortes nuevas, que es justamente donde más se concentra.
    CASE
        WHEN TRY_CONVERT(DATE, NULLIF(TRIM(c.fecha_baja), ''), 23)
             < CONVERT(DATE, TRIM(c.fecha_alta), 23)
            THEN CONVERT(DATE, TRIM(c.fecha_alta), 23)
        ELSE TRY_CONVERT(DATE, NULLIF(TRIM(c.fecha_baja), ''), 23)
    END,

    -- Coherencia exigida por CK_dim_cliente_baja_coherente:
    -- si no hay baja no puede haber motivo, y si hay baja tiene que haberlo.
    CASE
        WHEN TRY_CONVERT(DATE, NULLIF(TRIM(c.fecha_baja), ''), 23) IS NULL THEN NULL
        ELSE COALESCE(NULLIF(TRIM(c.motivo_baja), ''), 'Sin motivo declarado')
    END,

    TRIM(c.canal_alta),
    NULLIF(TRIM(c.email),    ''),
    NULLIF(TRIM(c.telefono), '')
FROM dbo.stg_clientes AS c;
GO


/* ============================================================================
   4. fact_facturacion
   ----------------------------------------------------------------------------
   Tres transformaciones:
     · Deduplicación: ROW_NUMBER por id_factura conservando una ocurrencia.
       Como los duplicados son filas idénticas, cuál se conserva es indistinto.
     · Fechas: COALESCE de TRY_CONVERT estilos 23 (yyyy-mm-dd) y 103
       (dd/mm/yyyy). El orden importa: se prueba primero el formato mayoritario.
     · Montos: los que superan 5 veces el precio del plan se dividen por 100
       (error de carga). Los negativos se conservan: son notas de crédito.

   periodo pasa de 'YYYY-MM' a DATE (día 1 del mes) para poder relacionarlo
   con una dimensión calendario en Power BI.
   ============================================================================ */

WITH dedup AS (
    SELECT
        f.*,
        ROW_NUMBER() OVER (PARTITION BY TRIM(f.id_factura)
                           ORDER BY (SELECT NULL)) AS rn
    FROM dbo.stg_facturacion AS f
)
INSERT INTO dbo.fact_facturacion
    (id_factura, id_cliente, periodo, id_plan, monto,
     fecha_vencimiento, fecha_pago, medio_pago)
SELECT
    TRIM(d.id_factura),
    TRIM(d.id_cliente),
    CONVERT(DATE, TRIM(d.periodo) + '-01'),
    TRIM(d.id_plan),

    CASE
        WHEN ABS(CONVERT(DECIMAL(16,2), TRIM(d.monto))) > p.precio_base * 5
            THEN CONVERT(DECIMAL(16,2), TRIM(d.monto)) / 100
        ELSE CONVERT(DECIMAL(16,2), TRIM(d.monto))
    END,

    CONVERT(DATE, TRIM(d.fecha_vencimiento), 23),

    COALESCE(
        TRY_CONVERT(DATE, NULLIF(TRIM(d.fecha_pago), ''), 23),
        TRY_CONVERT(DATE, NULLIF(TRIM(d.fecha_pago), ''), 103)
    ),

    -- Coherencia exigida por CK_fact_facturacion_pago_coherente.
    CASE
        WHEN NULLIF(TRIM(d.fecha_pago), '') IS NULL THEN NULL
        ELSE NULLIF(TRIM(d.medio_pago), '')
    END
FROM dedup AS d
JOIN dbo.dim_plan AS p ON p.id_plan = TRIM(d.id_plan)
WHERE d.rn = 1;
GO


/* ============================================================================
   5. fact_ticket
   ----------------------------------------------------------------------------
     · Huérfanos: excluidos con anti-join (ya están en rej_tickets_huerfanos).
     · satisfaccion: se castea vía DECIMAL porque el origen trae "5.0", que
       no convierte directo a TINYINT. Los valores fuera de 1-5 se anulan sin
       descartar el ticket: la gestión existió, lo inválido es la encuesta.
     · es_tecnico: flag calculado una sola vez acá, en lugar de repetir el CASE
       en cada consulta y en cada medida DAX.
   ============================================================================ */

INSERT INTO dbo.fact_ticket
    (id_ticket, id_cliente, fecha_apertura, fecha_cierre,
     categoria, canal, prioridad, satisfaccion, es_tecnico)
SELECT
    TRIM(t.id_ticket),
    TRIM(t.id_cliente),
    CONVERT(DATETIME2(0), TRIM(t.fecha_apertura), 120),
    TRY_CONVERT(DATETIME2(0), NULLIF(TRIM(t.fecha_cierre), ''), 120),
    TRIM(t.categoria),
    TRIM(t.canal),
    TRIM(t.prioridad),

    CASE
        WHEN TRY_CONVERT(DECIMAL(5,2), NULLIF(TRIM(t.satisfaccion), '')) BETWEEN 1 AND 5
            THEN CONVERT(TINYINT, TRY_CONVERT(DECIMAL(5,2), TRIM(t.satisfaccion)))
        ELSE NULL
    END,

    CASE
        WHEN TRIM(t.categoria) IN ('Sin conexión',
                                   'Conexión lenta / intermitencia',
                                   'WiFi / equipos')
            THEN 1 ELSE 0
    END
FROM dbo.stg_tickets AS t
JOIN dbo.dim_cliente AS c ON c.id_cliente = TRIM(t.id_cliente);
GO


/* ============================================================================
   6. VERIFICACIÓN
   ============================================================================ */

SELECT 'dim_plan'         AS tabla, COUNT(*) AS filas FROM dbo.dim_plan
UNION ALL SELECT 'dim_cliente',           COUNT(*) FROM dbo.dim_cliente
UNION ALL SELECT 'fact_facturacion',      COUNT(*) FROM dbo.fact_facturacion
UNION ALL SELECT 'fact_ticket',           COUNT(*) FROM dbo.fact_ticket
UNION ALL SELECT 'rej_tickets_huerfanos', COUNT(*) FROM dbo.rej_tickets_huerfanos;
-- Esperado: 6 | 5.215 | 100.820 | 31.251 | 90

-- Confirmación de que la normalización cerró el universo de categorías.
SELECT localidad, COUNT(*) AS clientes FROM dbo.dim_cliente GROUP BY localidad ORDER BY clientes DESC;
SELECT tipo_cliente, COUNT(*) AS clientes FROM dbo.dim_cliente GROUP BY tipo_cliente;
-- Esperado: exactamente 6 localidades y 2 tipos. Ningún NULL.

-- Si alguna de estas consultas devuelve filas, quedó un caso sin contemplar.
SELECT COUNT(*) AS localidades_nulas FROM dbo.dim_cliente WHERE localidad IS NULL;
SELECT COUNT(*) AS montos_aun_anomalos
FROM dbo.fact_facturacion AS f
JOIN dbo.dim_plan AS p ON p.id_plan = f.id_plan
WHERE ABS(f.monto) > p.precio_base * 5;
GO

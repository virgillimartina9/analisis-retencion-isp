/* ============================================================================
   PROYECTO : Análisis de Retención de Clientes en un ISP
   ARCHIVO  : 01_ddl_esquema.sql
   OBJETIVO : Crear el esquema completo (staging + modelo final).
   MOTOR    : SQL Server 2019+ / SQL Server Express
   NOTA     : Script re-ejecutable. Se puede correr las veces que haga falta.
   ============================================================================ */
CREATE DATABASE retencion_isp
COLLATE Latin1_General_100_CI_AS_SC_UTF8;
GO
USE retencion_isp;
GO
SELECT @@VERSION, DB_NAME(), DATABASEPROPERTYEX('retencion_isp','Collation');


USE retencion_isp;
GO

/* ============================================================================
   SECCIÓN 1 - CAPA STAGING
   ----------------------------------------------------------------------------
   Todas las columnas son VARCHAR(200) a propósito. Los archivos de origen
   traen fechas en dos formatos, valores fuera de rango y montos con errores
   de carga. Si se tipara acá, el BULK INSERT fallaría y no se podría medir
   cuántos registros están mal. Primero se ingesta todo, después se mide y
   recién al final se transforma.
   ============================================================================ */

DROP TABLE IF EXISTS dbo.stg_facturacion;
DROP TABLE IF EXISTS dbo.stg_tickets;
DROP TABLE IF EXISTS dbo.stg_clientes;
DROP TABLE IF EXISTS dbo.stg_planes;
GO

CREATE TABLE dbo.stg_planes (
    id_plan         VARCHAR(200) NULL,
    nombre_plan     VARCHAR(200) NULL,
    tipo_plan       VARCHAR(200) NULL,
    velocidad_mbps  VARCHAR(200) NULL,
    precio_base     VARCHAR(200) NULL
);
GO

CREATE TABLE dbo.stg_clientes (
    id_cliente      VARCHAR(200) NULL,
    tipo_cliente    VARCHAR(200) NULL,
    localidad       VARCHAR(200) NULL,
    id_plan         VARCHAR(200) NULL,
    fecha_alta      VARCHAR(200) NULL,
    fecha_baja      VARCHAR(200) NULL,
    motivo_baja     VARCHAR(200) NULL,
    canal_alta      VARCHAR(200) NULL,
    email           VARCHAR(200) NULL,
    telefono        VARCHAR(200) NULL
);
GO

CREATE TABLE dbo.stg_facturacion (
    id_factura         VARCHAR(200) NULL,
    id_cliente         VARCHAR(200) NULL,
    periodo            VARCHAR(200) NULL,
    id_plan            VARCHAR(200) NULL,
    monto              VARCHAR(200) NULL,
    fecha_vencimiento  VARCHAR(200) NULL,
    fecha_pago         VARCHAR(200) NULL,
    medio_pago         VARCHAR(200) NULL
);
GO

CREATE TABLE dbo.stg_tickets (
    id_ticket        VARCHAR(200) NULL,
    id_cliente       VARCHAR(200) NULL,
    fecha_apertura   VARCHAR(200) NULL,
    fecha_cierre     VARCHAR(200) NULL,
    categoria        VARCHAR(200) NULL,
    canal            VARCHAR(200) NULL,
    prioridad        VARCHAR(200) NULL,
    satisfaccion     VARCHAR(200) NULL
);
GO


/* ============================================================================
   SECCIÓN 2 - MODELO FINAL (esquema estrella)
   ----------------------------------------------------------------------------
   Dos dimensiones (cliente, plan) y dos tablas de hechos (facturación,
   tickets). Las restricciones NO son decorativas: son las que van a rechazar
   los datos sucios cuando se ejecute la transformación. Eso es intencional.
   El orden de DROP respeta las dependencias de clave foránea.
   ============================================================================ */

DROP TABLE IF EXISTS dbo.fact_facturacion;
DROP TABLE IF EXISTS dbo.fact_ticket;
DROP TABLE IF EXISTS dbo.dim_cliente;
DROP TABLE IF EXISTS dbo.dim_plan;
GO

-- ---------------------------------------------------------------- dim_plan
CREATE TABLE dbo.dim_plan (
    id_plan         CHAR(3)        NOT NULL,
    nombre_plan     VARCHAR(50)    NOT NULL,
    tipo_plan       VARCHAR(20)    NOT NULL,
    velocidad_mbps  INT            NOT NULL,
    precio_base     DECIMAL(12,2)  NOT NULL,
    CONSTRAINT PK_dim_plan PRIMARY KEY (id_plan),
    CONSTRAINT CK_dim_plan_velocidad CHECK (velocidad_mbps > 0),
    CONSTRAINT CK_dim_plan_precio    CHECK (precio_base   > 0)
);
GO

-- ------------------------------------------------------------- dim_cliente
CREATE TABLE dbo.dim_cliente (
    id_cliente      VARCHAR(10)   NOT NULL,
    tipo_cliente    VARCHAR(15)   NOT NULL,   -- normalizado: Residencial / Comercial
    localidad       VARCHAR(40)   NOT NULL,   -- normalizado: sin variantes de mayúsculas ni tildes
    id_plan         CHAR(3)       NOT NULL,
    fecha_alta      DATE          NOT NULL,
    fecha_baja      DATE          NULL,       -- NULL = cliente activo
    motivo_baja     VARCHAR(50)   NULL,
    canal_alta      VARCHAR(20)   NOT NULL,
    email           VARCHAR(120)  NULL,
    telefono        VARCHAR(30)   NULL,
    CONSTRAINT PK_dim_cliente PRIMARY KEY (id_cliente),
    CONSTRAINT FK_dim_cliente_plan
        FOREIGN KEY (id_plan) REFERENCES dbo.dim_plan (id_plan),
    CONSTRAINT CK_dim_cliente_tipo
        CHECK (tipo_cliente IN ('Residencial', 'Comercial')),
    -- Coherencia temporal: nadie se da de baja antes de darse de alta.
    CONSTRAINT CK_dim_cliente_fechas
        CHECK (fecha_baja IS NULL OR fecha_baja >= fecha_alta),
    -- Si hay fecha de baja tiene que haber motivo, y viceversa.
    CONSTRAINT CK_dim_cliente_baja_coherente
        CHECK ((fecha_baja IS NULL AND motivo_baja IS NULL)
            OR (fecha_baja IS NOT NULL AND motivo_baja IS NOT NULL))
);
GO

-- -------------------------------------------------------- fact_facturacion
CREATE TABLE dbo.fact_facturacion (
    id_factura         VARCHAR(10)    NOT NULL,
    id_cliente         VARCHAR(10)    NOT NULL,
    -- periodo se guarda como DATE (día 1 del mes) y no como texto 'YYYY-MM'.
    -- Motivo: permite relacionarlo con una dimensión calendario en Power BI
    -- y ordenar cronológicamente sin trucos.
    periodo            DATE           NOT NULL,
    id_plan            CHAR(3)        NOT NULL,
    monto              DECIMAL(12,2)  NOT NULL,
    fecha_vencimiento  DATE           NOT NULL,
    fecha_pago         DATE           NULL,   -- NULL = factura impaga
    medio_pago         VARCHAR(30)    NULL,   -- NULL si está impaga
    CONSTRAINT PK_fact_facturacion PRIMARY KEY (id_factura),
    CONSTRAINT FK_fact_facturacion_cliente
        FOREIGN KEY (id_cliente) REFERENCES dbo.dim_cliente (id_cliente),
    CONSTRAINT FK_fact_facturacion_plan
        FOREIGN KEY (id_plan) REFERENCES dbo.dim_plan (id_plan),
    -- Si está impaga no puede tener medio de pago.
    CONSTRAINT CK_fact_facturacion_pago_coherente
        CHECK ((fecha_pago IS NULL AND medio_pago IS NULL)
            OR (fecha_pago IS NOT NULL AND medio_pago IS NOT NULL))
);
GO

-- ------------------------------------------------------------- fact_ticket
CREATE TABLE dbo.fact_ticket (
    id_ticket        VARCHAR(10)   NOT NULL,
    id_cliente       VARCHAR(10)   NOT NULL,
    fecha_apertura   DATETIME2(0)  NOT NULL,
    fecha_cierre     DATETIME2(0)  NULL,      -- NULL = ticket abierto
    categoria        VARCHAR(40)   NOT NULL,
    canal            VARCHAR(20)   NOT NULL,
    prioridad        VARCHAR(10)   NOT NULL,
    satisfaccion     TINYINT       NULL,      -- 1 a 5; NULL = sin encuesta
    -- Flag derivado. Se calcula una vez en la carga y evita repetir el CASE
    -- con las tres categorías técnicas en cada consulta y en cada medida DAX.
    es_tecnico       BIT           NOT NULL,
    CONSTRAINT PK_fact_ticket PRIMARY KEY (id_ticket),
    CONSTRAINT FK_fact_ticket_cliente
        FOREIGN KEY (id_cliente) REFERENCES dbo.dim_cliente (id_cliente),
    CONSTRAINT CK_fact_ticket_prioridad
        CHECK (prioridad IN ('Alta', 'Media', 'Baja')),
    CONSTRAINT CK_fact_ticket_satisfaccion
        CHECK (satisfaccion IS NULL OR satisfaccion BETWEEN 1 AND 5),
    CONSTRAINT CK_fact_ticket_fechas
        CHECK (fecha_cierre IS NULL OR fecha_cierre >= fecha_apertura)
);
GO


/* ============================================================================
   SECCIÓN 3 - ÍNDICES
   ----------------------------------------------------------------------------
   Las claves primarias ya generan un índice clustered. Estos son los índices
   de apoyo para los patrones de consulta del análisis: filtrar por cliente,
   recorrer por período y separar activos de bajas.
   ============================================================================ */

CREATE INDEX IX_fact_facturacion_cliente  ON dbo.fact_facturacion (id_cliente);
CREATE INDEX IX_fact_facturacion_periodo  ON dbo.fact_facturacion (periodo)
    INCLUDE (monto, fecha_pago);
CREATE INDEX IX_fact_ticket_cliente       ON dbo.fact_ticket (id_cliente, fecha_apertura);
CREATE INDEX IX_fact_ticket_apertura      ON dbo.fact_ticket (fecha_apertura)
    INCLUDE (es_tecnico, satisfaccion);
CREATE INDEX IX_dim_cliente_baja          ON dbo.dim_cliente (fecha_baja);
GO


/* ============================================================================
   SECCIÓN 4 - REGISTRO DE CONTROLES DE CALIDAD
   ----------------------------------------------------------------------------
   Los controles del script 03 escriben acá sus resultados. Así los hallazgos
   quedan como dato consultable y versionable, no como una captura de pantalla
   suelta. De esta tabla sale la sección "Problemas de calidad encontrados"
   del README.
   ============================================================================ */

DROP TABLE IF EXISTS dbo.qa_resultados;
GO

CREATE TABLE dbo.qa_resultados (
    id_control       INT IDENTITY(1,1) NOT NULL,
    fecha_ejecucion  DATETIME2(0)  NOT NULL CONSTRAINT DF_qa_fecha DEFAULT SYSDATETIME(),
    tabla_origen     VARCHAR(50)   NOT NULL,
    control          VARCHAR(120)  NOT NULL,
    registros        INT           NOT NULL,
    pct_total        DECIMAL(6,2)  NULL,
    decision         VARCHAR(300)  NULL,   -- qué se hizo y por qué
    CONSTRAINT PK_qa_resultados PRIMARY KEY (id_control)
);
GO


/* ============================================================================
   VERIFICACIÓN FINAL
   ============================================================================ */

SELECT
    t.name              AS tabla,
    COUNT(c.column_id)  AS columnas
FROM sys.tables AS t
JOIN sys.columns AS c ON c.object_id = t.object_id
GROUP BY t.name
ORDER BY
    CASE WHEN t.name LIKE 'stg_%' THEN 1 
         WHEN t.name LIKE 'dim_%' THEN 2
         WHEN t.name LIKE 'fact_%' THEN 3 
         ELSE 4 
    END,
    t.name;
GO

-- Esperado: 4 tablas stg_, 2 dim_, 2 fact_, 1 qa_ = 9 tablas.

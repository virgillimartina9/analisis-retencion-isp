/* ============================================================================
   PROYECTO : Análisis de Retención de Clientes en un ISP
   ARCHIVO  : 02_carga_staging.sql
   OBJETIVO : Cargar los 4 CSV de origen en la capa staging.
   REQUIERE : 01_ddl_esquema.sql ejecutado.
   NOTA     : Script re-ejecutable. Trunca staging antes de cargar, así que se
              puede correr las veces que haga falta sin duplicar registros.

   ANTES DE EJECUTAR:
     1. Copiar los 4 CSV en la carpeta datos/raw/ del proyecto.
     2. Editar @ruta_datos (línea de abajo) con la ruta absoluta de esa carpeta,
        terminada en barra invertida.

   La ruta la abre el servicio de SQL Server, no SSMS. En una instancia local
   es el mismo disco; en un servidor remoto sería el disco del servidor.
   ============================================================================ */

USE retencion_isp;
GO

-- ⚠ ÚNICA LÍNEA A EDITAR
DECLARE @ruta_datos NVARCHAR(300) = N'C:\Proyectos\analisis-retencion-isp\datos\raw\';

DECLARE @sql NVARCHAR(MAX);


/* ----------------------------------------------------------------------------
   1. Vaciar staging
   TRUNCATE en vez de DELETE: no registra fila por fila en el log y reinicia
   la tabla al instante. Es válido acá porque staging no tiene claves foráneas
   apuntándole.
   ---------------------------------------------------------------------------- */
TRUNCATE TABLE dbo.stg_planes;
TRUNCATE TABLE dbo.stg_clientes;
TRUNCATE TABLE dbo.stg_facturacion;
TRUNCATE TABLE dbo.stg_tickets;


/* ----------------------------------------------------------------------------
   2. Carga masiva
   BULK INSERT no acepta variables en la cláusula FROM, por eso se arma la
   sentencia como texto y se ejecuta con sp_executesql. Así la ruta queda
   definida en un solo lugar en vez de repetida cuatro veces.

   Parámetros:
     FORMAT='CSV'        respeta comillas y comas dentro de campos entrecomillados
     FIRSTROW=2          saltea la fila de encabezados
     ROWTERMINATOR=0x0a  salto de línea Unix (los archivos NO son CRLF de Windows)
     CODEPAGE='65001'    UTF-8. Sin esto, "Básico 50" se carga como "BÃ¡sico 50"
     TABLOCK             habilita minimal logging y acelera la carga
     BATCHSIZE           confirma por lotes: si falla en la fila 90.000 no se
                         pierde todo lo cargado antes
   ---------------------------------------------------------------------------- */

PRINT '--- Cargando planes...';
SET @sql = N'
BULK INSERT dbo.stg_planes
FROM ''' + @ruta_datos + N'planes.csv''
WITH (FORMAT=''CSV'', FIRSTROW=2, FIELDTERMINATOR='','',
      ROWTERMINATOR=''0x0a'', CODEPAGE=''65001'', TABLOCK);';
EXEC sp_executesql @sql;

PRINT '--- Cargando clientes...';
SET @sql = N'
BULK INSERT dbo.stg_clientes
FROM ''' + @ruta_datos + N'clientes.csv''
WITH (FORMAT=''CSV'', FIRSTROW=2, FIELDTERMINATOR='','',
      ROWTERMINATOR=''0x0a'', CODEPAGE=''65001'', TABLOCK, BATCHSIZE=5000);';
EXEC sp_executesql @sql;

PRINT '--- Cargando facturacion...';
SET @sql = N'
BULK INSERT dbo.stg_facturacion
FROM ''' + @ruta_datos + N'facturacion.csv''
WITH (FORMAT=''CSV'', FIRSTROW=2, FIELDTERMINATOR='','',
      ROWTERMINATOR=''0x0a'', CODEPAGE=''65001'', TABLOCK, BATCHSIZE=20000);';
EXEC sp_executesql @sql;

PRINT '--- Cargando tickets...';
SET @sql = N'
BULK INSERT dbo.stg_tickets
FROM ''' + @ruta_datos + N'tickets.csv''
WITH (FORMAT=''CSV'', FIRSTROW=2, FIELDTERMINATOR='','',
      ROWTERMINATOR=''0x0a'', CODEPAGE=''65001'', TABLOCK, BATCHSIZE=10000);';
EXEC sp_executesql @sql;

PRINT '--- Carga finalizada.';
GO


/* ----------------------------------------------------------------------------
   3. Verificación de integridad de la carga
   Todas las filas tienen que estar OK antes de seguir al script 03.
   ---------------------------------------------------------------------------- */

SELECT 'stg_planes'      AS tabla, COUNT(*) AS cargadas,      6 AS esperadas FROM dbo.stg_planes
UNION ALL
SELECT 'stg_clientes',        COUNT(*),   5215 FROM dbo.stg_clientes
UNION ALL
SELECT 'stg_facturacion',     COUNT(*), 101300 FROM dbo.stg_facturacion
UNION ALL
SELECT 'stg_tickets',         COUNT(*),  31341 FROM dbo.stg_tickets;
GO

-- Control de encoding: si aparecen caracteres raros, faltó CODEPAGE='65001'.
SELECT nombre_plan FROM dbo.stg_planes ORDER BY id_plan;
-- Esperado: 'Básico 50' con tilde, no 'BÃ¡sico 50'.

-- Control de desfase de columnas: si el separador o el terminador de fila
-- estuvieran mal, los valores aparecerían corridos de columna.
SELECT TOP 5 * FROM dbo.stg_facturacion;
SELECT TOP 5 * FROM dbo.stg_tickets;
GO

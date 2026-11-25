-- =====================================================================
-- 02_calidad.sql  |  Control de calidad de las capas (taller 5.4)
-- Proyecto: localizacion optima de un centro de salud en Bosa (Bogota)
-- SRID de trabajo: 9377 (MAGNA-SIRGAS Origen Nacional, metros)
-- Ejecutar completo en pgAdmin (F5). Esquema: analisis
-- =====================================================================

-- QC1. Consistencia de sistemas de referencia: todas deben ser 9377
SELECT f_table_name AS tabla, srid, type AS tipo_geometria
FROM geometry_columns
WHERE f_table_schema = 'analisis'
ORDER BY 1;

-- QC2. Geometrias invalidas, vacias o nulas por tabla (antes de reparar)
SELECT 'lotes' AS tabla, COUNT(*) AS total,
       COUNT(*) FILTER (WHERE NOT ST_IsValid(geom)) AS invalidas,
       COUNT(*) FILTER (WHERE ST_IsEmpty(geom) OR geom IS NULL) AS vacias_o_nulas
FROM analisis.lotes
UNION ALL
SELECT 'calzadas', COUNT(*), COUNT(*) FILTER (WHERE NOT ST_IsValid(geom)),
       COUNT(*) FILTER (WHERE ST_IsEmpty(geom) OR geom IS NULL) FROM analisis.calzadas
UNION ALL
SELECT 'barrios', COUNT(*), COUNT(*) FILTER (WHERE NOT ST_IsValid(geom)),
       COUNT(*) FILTER (WHERE ST_IsEmpty(geom) OR geom IS NULL) FROM analisis.barrios
UNION ALL
SELECT 'amenaza_jarillon', COUNT(*), COUNT(*) FILTER (WHERE NOT ST_IsValid(geom)),
       COUNT(*) FILTER (WHERE ST_IsEmpty(geom) OR geom IS NULL) FROM analisis.amenaza_jarillon
UNION ALL
SELECT 'centros_salud', COUNT(*), COUNT(*) FILTER (WHERE NOT ST_IsValid(geom)),
       COUNT(*) FILTER (WHERE ST_IsEmpty(geom) OR geom IS NULL) FROM analisis.centros_salud
UNION ALL
SELECT 'limite_bosa', COUNT(*), COUNT(*) FILTER (WHERE NOT ST_IsValid(geom)),
       COUNT(*) FILTER (WHERE ST_IsEmpty(geom) OR geom IS NULL) FROM analisis.limite_bosa;

-- QC3. Motivo de invalidez (trazabilidad)
SELECT id, lotcodigo, ST_IsValidReason(geom) AS motivo
FROM analisis.lotes
WHERE NOT ST_IsValid(geom);

-- QC4. Reparar geometrias invalidas (se conserva solo la parte poligonal)
UPDATE analisis.lotes
SET geom = ST_Multi(ST_CollectionExtract(ST_MakeValid(geom), 3))
WHERE NOT ST_IsValid(geom);

UPDATE analisis.calzadas
SET geom = ST_Multi(ST_CollectionExtract(ST_MakeValid(geom), 3))
WHERE NOT ST_IsValid(geom);

-- QC5. Verificar que ya no quedan invalidas (debe dar 0)
SELECT COUNT(*) AS lotes_invalidos_restantes
FROM analisis.lotes WHERE NOT ST_IsValid(geom);

-- QC6. Duplicidades: codigos de lote repetidos
SELECT lotcodigo, COUNT(*) AS veces
FROM analisis.lotes
GROUP BY lotcodigo
HAVING COUNT(*) > 1
ORDER BY veces DESC
LIMIT 20;

-- QC7. Duplicidades: geometrias identicas en lotes
SELECT COUNT(*) AS lotes_con_geometria_repetida
FROM (
  SELECT ST_AsBinary(geom) AS g
  FROM analisis.lotes
  GROUP BY ST_AsBinary(geom)
  HAVING COUNT(*) > 1
) t;

-- QC8. Restriccion espacial: lotes cuyo punto interior queda fuera del limite de Bosa
SELECT COUNT(*) AS lotes_fuera_del_limite
FROM analisis.lotes l
WHERE NOT EXISTS (
  SELECT 1 FROM analisis.limite_bosa b
  WHERE ST_Within(ST_PointOnSurface(l.geom), b.geom)
);

-- QC9. Restricciones de integridad (areas y numero de predios coherentes)
ALTER TABLE analisis.lotes DROP CONSTRAINT IF EXISTS ck_lotes_area;
ALTER TABLE analisis.lotes ADD CONSTRAINT ck_lotes_area CHECK (area_m2 > 0);
ALTER TABLE analisis.lotes DROP CONSTRAINT IF EXISTS ck_lotes_predios;
ALTER TABLE analisis.lotes ADD CONSTRAINT ck_lotes_predios CHECK (lotupredia >= 0);

-- QC10. Indices espaciales presentes (deben existir uno por tabla)
SELECT tablename, indexname
FROM pg_indexes
WHERE schemaname = 'analisis' AND indexdef ILIKE '%gist%'
ORDER BY 1;

-- Actualizar estadisticas para el planificador de consultas
ANALYZE analisis.lotes;
ANALYZE analisis.calzadas;
ANALYZE analisis.barrios;
ANALYZE analisis.amenaza_jarillon;
ANALYZE analisis.centros_salud;
ANALYZE analisis.limite_bosa;

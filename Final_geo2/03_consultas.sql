-- =====================================================================
-- 03_consultas.sql  |  22 consultas documentadas (taller 5.2)
-- Escenario: nuevo centro de salud en Bosa (Bogota). SRID 9377 (metros).
-- Capas: limite_bosa, barrios, lotes, calzadas, centros_salud, amenaza_jarillon
-- Nota: "poblacion" se aproxima con lotupredia (n.o de predios por lote).
-- Ejecutar cada consulta por separado (seleccionar + F5) o todo el archivo.
-- =====================================================================

-- ---------------------------------------------------------------------
-- PREPARACION
-- ---------------------------------------------------------------------

-- Q00 [Preparacion] Subdividir la amenaza en piezas pequenas (ST_Subdivide) e indexarlas.
-- Objetivo: los poligonos de amenaza son muy grandes; subdividirlos hace que
-- ST_Intersects con 76.000 lotes pase de minutos a segundos.
DROP TABLE IF EXISTS analisis.amenaza_sub;
CREATE TABLE analisis.amenaza_sub AS
SELECT ST_Subdivide(geom, 256) AS geom
FROM analisis.amenaza_jarillon;
CREATE INDEX amenaza_sub_geom_idx ON analisis.amenaza_sub USING GIST (geom);
ANALYZE analisis.amenaza_sub;

-- ---------------------------------------------------------------------
-- DESCRIPTIVAS (2)
-- ---------------------------------------------------------------------

-- Q01 [Descriptiva] Conteo de elementos por capa.
-- Objetivo: dimensionar la base de datos. Tablas: todas.
SELECT 'barrios' AS capa, COUNT(*) AS elementos FROM analisis.barrios
UNION ALL SELECT 'calzadas', COUNT(*) FROM analisis.calzadas
UNION ALL SELECT 'lotes', COUNT(*) FROM analisis.lotes
UNION ALL SELECT 'centros_salud', COUNT(*) FROM analisis.centros_salud
UNION ALL SELECT 'amenaza_jarillon', COUNT(*) FROM analisis.amenaza_jarillon
UNION ALL SELECT 'limite_bosa', COUNT(*) FROM analisis.limite_bosa;

-- Q02 [Descriptiva] Estadisticos del area de los lotes (m2).
-- Objetivo: definir un rango de area razonable para un centro de salud.
SELECT COUNT(*) AS lotes,
       ROUND(MIN(area_m2)::numeric, 1) AS minimo,
       ROUND(AVG(area_m2)::numeric, 1) AS promedio,
       ROUND((PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY area_m2))::numeric, 1) AS mediana,
       ROUND((PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY area_m2))::numeric, 1) AS p95,
       ROUND(MAX(area_m2)::numeric, 1) AS maximo
FROM analisis.lotes;

-- ---------------------------------------------------------------------
-- ESPACIALES (2)
-- ---------------------------------------------------------------------

-- Q03 [Espacial] Lotes a menos de 1 km de un centro de salud (ST_DWithin).
-- Objetivo: medir la cobertura caminable actual.
SELECT COUNT(DISTINCT l.id) AS lotes_a_menos_de_1km,
       (SELECT COUNT(*) FROM analisis.lotes) AS total_lotes
FROM analisis.lotes l
JOIN analisis.centros_salud s ON ST_DWithin(l.geom, s.geom, 1000);

-- Q04 [Espacial] Lotes que intersectan la amenaza por rompimiento de jarillon
-- (ST_Intersects). Objetivo: dimensionar la restriccion excluyente.
SELECT COUNT(*) FILTER (WHERE EXISTS (
         SELECT 1 FROM analisis.amenaza_sub s WHERE ST_Intersects(l.geom, s.geom))
       ) AS lotes_en_amenaza,
       COUNT(*) AS total_lotes
FROM analisis.lotes l;

-- ---------------------------------------------------------------------
-- AGREGACIONES (3)
-- ---------------------------------------------------------------------

-- Q05 [Agregacion] Numero de lotes y area total por barrio (ST_Within + ST_PointOnSurface).
SELECT b.scanombre AS barrio,
       COUNT(l.id) AS lotes,
       ROUND((SUM(l.area_m2) / 10000)::numeric, 2) AS hectareas_lotes
FROM analisis.barrios b
JOIN analisis.lotes l ON ST_Within(ST_PointOnSurface(l.geom), b.geom)
GROUP BY b.scanombre
ORDER BY lotes DESC
LIMIT 15;

-- Q06 [Agregacion] Predios por barrio (indicador indirecto de poblacion).
SELECT b.scanombre AS barrio, SUM(l.lotupredia) AS predios
FROM analisis.barrios b
JOIN analisis.lotes l ON ST_Within(ST_PointOnSurface(l.geom), b.geom)
GROUP BY b.scanombre
ORDER BY predios DESC
LIMIT 10;

-- Q07 [Agregacion] Area de amenaza por clase de suelo dentro de Bosa y su
-- porcentaje respecto al area de la localidad (ST_Intersection + ST_Area).
SELECT a.clase_suel,
       ROUND((SUM(ST_Area(ST_Intersection(a.geom, b.geom))) / 1e6)::numeric, 2) AS km2_amenaza,
       ROUND((100 * SUM(ST_Area(ST_Intersection(a.geom, b.geom))) / MAX(ST_Area(b.geom)))::numeric, 1) AS pct_de_bosa
FROM analisis.amenaza_jarillon a
CROSS JOIN analisis.limite_bosa b
GROUP BY a.clase_suel
ORDER BY km2_amenaza DESC;

-- ---------------------------------------------------------------------
-- CTE / SUBCONSULTAS (4)
-- ---------------------------------------------------------------------

-- Q08 [CTE] Lotes candidatos: area 1.000-10.000 m2, dentro de Bosa y fuera de amenaza.
WITH candidatos AS (
  SELECT l.id, l.area_m2
  FROM analisis.lotes l, analisis.limite_bosa b
  WHERE l.area_m2 BETWEEN 1000 AND 10000
    AND ST_Within(ST_PointOnSurface(l.geom), b.geom)
    AND NOT EXISTS (SELECT 1 FROM analisis.amenaza_sub s WHERE ST_Intersects(l.geom, s.geom))
)
SELECT COUNT(*) AS lotes_candidatos,
       ROUND(AVG(area_m2)::numeric, 1) AS area_promedio_m2
FROM candidatos;

-- Q09 [CTE] Candidatos en deficit de cobertura: a mas de 1.500 m de cualquier centro de salud.
WITH candidatos AS (
  SELECT l.id, l.geom
  FROM analisis.lotes l, analisis.limite_bosa b
  WHERE l.area_m2 BETWEEN 1000 AND 10000
    AND ST_Within(ST_PointOnSurface(l.geom), b.geom)
    AND NOT EXISTS (SELECT 1 FROM analisis.amenaza_sub s WHERE ST_Intersects(l.geom, s.geom))
)
SELECT COUNT(*) AS candidatos_en_deficit
FROM candidatos c
WHERE NOT EXISTS (
  SELECT 1 FROM analisis.centros_salud s WHERE ST_DWithin(c.geom, s.geom, 1500)
);

-- Q10 [Subconsulta] Barrios sin ningun centro de salud dentro de su limite.
SELECT COUNT(*) AS barrios_sin_centro,
       (SELECT COUNT(*) FROM analisis.barrios) AS barrios_totales
FROM analisis.barrios b
WHERE NOT EXISTS (
  SELECT 1 FROM analisis.centros_salud s WHERE ST_Within(s.geom, b.geom)
);

-- Q11 [CTE doble] Candidatos con via ancha (>= 12 m) a menos de 150 m y fuera de amenaza.
WITH vias_anchas AS (
  SELECT geom FROM analisis.calzadas WHERE calancho >= 12
),
candidatos AS (
  SELECT l.id, l.geom
  FROM analisis.lotes l, analisis.limite_bosa b
  WHERE l.area_m2 BETWEEN 1000 AND 10000
    AND ST_Within(ST_PointOnSurface(l.geom), b.geom)
    AND NOT EXISTS (SELECT 1 FROM analisis.amenaza_sub s WHERE ST_Intersects(l.geom, s.geom))
)
SELECT COUNT(*) AS candidatos_con_via_ancha_cerca
FROM candidatos c
WHERE EXISTS (SELECT 1 FROM vias_anchas v WHERE ST_DWithin(c.geom, v.geom, 150));

-- ---------------------------------------------------------------------
-- PRIORIZACION (2)
-- ---------------------------------------------------------------------

-- Q12 [Priorizacion] Ranking de barrios por distancia del centroide al centro de
-- salud mas cercano (ST_Centroid + ST_Distance + RANK).
WITH dist AS (
  SELECT b.scanombre AS barrio,
         (SELECT MIN(ST_Distance(ST_Centroid(b.geom), s.geom)) FROM analisis.centros_salud s) AS dist_m
  FROM analisis.barrios b
  WHERE ST_Within(ST_Centroid(b.geom), (SELECT geom FROM analisis.limite_bosa))
)
SELECT RANK() OVER (ORDER BY dist_m DESC) AS puesto,
       barrio, ROUND(dist_m::numeric) AS metros_al_centro_mas_cercano
FROM dist
ORDER BY puesto
LIMIT 10;

-- Q13 [Priorizacion] Ranking preliminar de lotes candidatos por area (RANK).
SELECT RANK() OVER (ORDER BY l.area_m2 DESC) AS puesto,
       l.lotcodigo, ROUND(l.area_m2::numeric) AS area_m2
FROM analisis.lotes l, analisis.limite_bosa b
WHERE l.area_m2 BETWEEN 1000 AND 10000
  AND ST_Within(ST_PointOnSurface(l.geom), b.geom)
  AND NOT EXISTS (SELECT 1 FROM analisis.amenaza_sub s WHERE ST_Intersects(l.geom, s.geom))
ORDER BY puesto
LIMIT 10;

-- ---------------------------------------------------------------------
-- OTRAS CONSULTAS DE ANALISIS Y VALIDACION (9)
-- ---------------------------------------------------------------------

-- Q14 [Distancia] Distancia de cada centro de salud al limite de Bosa (ST_Distance).
SELECT s.sede_nombre, s.localidad, s.complejidad,
       ROUND(ST_Distance(s.geom, b.geom)::numeric) AS metros_al_limite_de_bosa
FROM analisis.centros_salud s, analisis.limite_bosa b
ORDER BY 4;

-- Q15 [Buffer] Cobertura del Hospital de Bosa con un radio de 1 km (ST_Buffer):
-- area cubierta y predios dentro del radio.
WITH hosp AS (
  SELECT ST_Buffer(geom, 1000) AS zona
  FROM analisis.centros_salud
  WHERE sede_nombre ILIKE '%Hospital de Bosa%'
)
SELECT ROUND((ST_Area(ST_Intersection(h.zona, b.geom)) / 1e6)::numeric, 2) AS km2_de_bosa_cubiertos,
       (SELECT SUM(l.lotupredia) FROM analisis.lotes l WHERE ST_Intersects(l.geom, h.zona)) AS predios_cubiertos
FROM hosp h, analisis.limite_bosa b;

-- Q16 [Union y diferencia] Porcentaje de Bosa sin cobertura a 1,5 km de cualquier
-- centro de salud (ST_Union + ST_Difference + ST_Area).
WITH cobertura AS (
  SELECT ST_Union(ST_Buffer(geom, 1500)) AS g FROM analisis.centros_salud
)
SELECT ROUND((ST_Area(b.geom) / 1e6)::numeric, 2) AS km2_bosa,
       ROUND((ST_Area(ST_Difference(b.geom, c.g)) / 1e6)::numeric, 2) AS km2_sin_cobertura,
       ROUND((100 * ST_Area(ST_Difference(b.geom, c.g)) / ST_Area(b.geom))::numeric, 1) AS pct_sin_cobertura
FROM analisis.limite_bosa b, cobertura c;

-- Q17 [Agregacion] Area de calzada por tipo de funcion y ancho medio.
SELECT calfuncion,
       COUNT(*) AS segmentos,
       ROUND((SUM(ST_Area(geom)) / 1e4)::numeric, 1) AS hectareas,
       ROUND(AVG(calancho)::numeric, 1) AS ancho_medio_m
FROM analisis.calzadas
GROUP BY calfuncion
ORDER BY calfuncion;

-- Q18 [Vecino mas cercano] Centro de salud mas cercano a cada uno de los 10 barrios
-- mas grandes (LATERAL + operador <-> con indice espacial).
SELECT b.scanombre AS barrio, s.sede_nombre AS centro_mas_cercano,
       ROUND(ST_Distance(ST_Centroid(b.geom), s.geom)::numeric) AS metros
FROM (
  SELECT * FROM analisis.barrios
  WHERE ST_Within(ST_Centroid(geom), (SELECT geom FROM analisis.limite_bosa))
  ORDER BY ST_Area(geom) DESC LIMIT 10
) b
CROSS JOIN LATERAL (
  SELECT sede_nombre, geom FROM analisis.centros_salud
  ORDER BY geom <-> ST_Centroid(b.geom) LIMIT 1
) s
ORDER BY metros DESC;

-- Q19 [Calidad] Geometrias invalidas restantes tras la reparacion (debe dar 0).
SELECT 'lotes' AS tabla, COUNT(*) AS invalidas FROM analisis.lotes WHERE NOT ST_IsValid(geom)
UNION ALL SELECT 'calzadas', COUNT(*) FROM analisis.calzadas WHERE NOT ST_IsValid(geom);

-- Q20 [Calidad] Codigos de lote duplicados (trazabilidad).
SELECT COUNT(*) AS codigos_duplicados
FROM (SELECT lotcodigo FROM analisis.lotes GROUP BY lotcodigo HAVING COUNT(*) > 1) t;

-- Q21 [Calidad] Consistencia de SRID: todas las capas deben usar 9377 (ST_SRID).
SELECT 'lotes' AS capa, ST_SRID(geom) AS srid FROM analisis.lotes LIMIT 1;

-- Q22 [Validacion] Lotes candidatos que caen en mas de un barrio (solapes de limites).
SELECT COUNT(*) AS lotes_en_mas_de_un_barrio
FROM (
  SELECT l.id
  FROM analisis.lotes l
  JOIN analisis.barrios b ON ST_Intersects(ST_PointOnSurface(l.geom), b.geom)
  WHERE l.area_m2 BETWEEN 1000 AND 10000
  GROUP BY l.id
  HAVING COUNT(*) > 1
) t;

-- =====================================================================
-- 04_multicriterio.sql  |  Analisis multicriterio (taller 5.3 y 5.5)
-- Escenario: nuevo centro de salud en Bosa. SRID 9377.
-- Requiere haber corrido antes 02_calidad.sql y el bloque Q00 de 03_consultas.sql
-- (tabla analisis.amenaza_sub).
--
-- RESTRICCIONES EXCLUYENTES (un lote que no las cumpla no es candidato):
--   R1. El punto interior del lote esta dentro de la localidad de Bosa.
--   R2. El lote NO intersecta la zona de amenaza por rompimiento de jarillon.
--   R3. Area entre 1.000 y 10.000 m2 (suelo suficiente para un centro de salud).
--
-- CRITERIOS (5) Y PESOS BASE
--   C1 Deficit de cobertura  30 %  distancia al centro de salud mas cercano (mas lejos = mejor)
--   C2 Poblacion beneficiada 25 %  predios (lotupredia) a menos de 1 km (mas = mejor)
--   C3 Accesibilidad vial    20 %  distancia a via ancha (>= 12 m) (mas cerca = mejor)
--   C4 Seguridad ante inundacion 15 %  distancia a la zona de amenaza (mas lejos = mejor)
--   C5 Disponibilidad de suelo 10 %  area del lote (mas grande = mejor)
-- Nota: no hay capa de uso del suelo, por eso la "compatibilidad" se aproxima
-- con C4 (seguridad frente a la amenaza). La poblacion se aproxima con predios.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0. Preparacion (si no corriste el bloque Q00 de 03_consultas.sql)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS analisis.amenaza_sub AS
SELECT ST_Subdivide(geom, 256) AS geom FROM analisis.amenaza_jarillon;
CREATE INDEX IF NOT EXISTS amenaza_sub_geom_idx ON analisis.amenaza_sub USING GIST (geom);

-- ---------------------------------------------------------------------
-- 1. Tabla de candidatos con los indicadores crudos (sin normalizar)
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS analisis.candidatos CASCADE;

CREATE TABLE analisis.candidatos AS
WITH base AS (
  SELECT l.id, l.lotcodigo, l.manzcodigo, l.area_m2, l.geom,
         ST_PointOnSurface(l.geom) AS pt
  FROM analisis.lotes l, analisis.limite_bosa b
  WHERE l.area_m2 BETWEEN 1000 AND 10000                                   -- R3
    AND ST_Within(ST_PointOnSurface(l.geom), b.geom)                       -- R1
    AND NOT EXISTS (SELECT 1 FROM analisis.amenaza_sub s
                    WHERE ST_Intersects(l.geom, s.geom))                   -- R2
)
SELECT
  c.id, c.lotcodigo, c.manzcodigo, c.area_m2, c.geom,
  (SELECT bb.scanombre FROM analisis.barrios bb
    WHERE ST_Within(c.pt, bb.geom) LIMIT 1)                                AS barrio,
  -- C1: distancia (m) al centro de salud mas cercano
  (SELECT MIN(ST_Distance(c.geom, s.geom)) FROM analisis.centros_salud s)  AS d_salud_m,
  -- C2: predios a menos de 1 km (indicador indirecto de poblacion)
  (SELECT COALESCE(SUM(l2.lotupredia), 0) FROM analisis.lotes l2
    WHERE ST_DWithin(l2.geom, c.pt, 1000))                                 AS predios_1km,
  -- C3: distancia (m) a la via ancha mas cercana (tope 3.000 m)
  COALESCE((SELECT MIN(ST_Distance(c.geom, v.geom)) FROM analisis.calzadas v
             WHERE v.calancho >= 12 AND ST_DWithin(v.geom, c.geom, 3000)), 3000) AS d_via_m,
  -- C4: distancia (m) a la zona de amenaza (tope 2.000 m)
  COALESCE((SELECT MIN(ST_Distance(c.geom, s.geom)) FROM analisis.amenaza_sub s
             WHERE ST_DWithin(s.geom, c.geom, 2000)), 2000)                AS d_amenaza_m
FROM base c;

ALTER TABLE analisis.candidatos ADD PRIMARY KEY (id);
CREATE INDEX candidatos_geom_idx ON analisis.candidatos USING GIST (geom);
ANALYZE analisis.candidatos;

-- Verificacion: numero de candidatos y rangos de los indicadores
SELECT COUNT(*) AS candidatos,
       ROUND(MIN(d_salud_m)::numeric) AS min_d_salud, ROUND(MAX(d_salud_m)::numeric) AS max_d_salud,
       MIN(predios_1km) AS min_predios, MAX(predios_1km) AS max_predios,
       ROUND(MIN(d_via_m)::numeric) AS min_d_via, ROUND(MAX(d_via_m)::numeric) AS max_d_via,
       ROUND(MIN(d_amenaza_m)::numeric) AS min_d_amenaza, ROUND(MAX(d_amenaza_m)::numeric) AS max_d_amenaza
FROM analisis.candidatos;

-- ---------------------------------------------------------------------
-- 2. Normalizacion min-max (0 a 1; 1 = mejor)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW analisis.vw_indicadores_normalizados AS
SELECT
  id, lotcodigo, barrio, area_m2, geom,
  COALESCE((d_salud_m   - MIN(d_salud_m)   OVER ()) / NULLIF(MAX(d_salud_m)   OVER () - MIN(d_salud_m)   OVER (), 0), 0) AS n_deficit,
  COALESCE((predios_1km - MIN(predios_1km) OVER ())::numeric / NULLIF(MAX(predios_1km) OVER () - MIN(predios_1km) OVER (), 0), 0) AS n_poblacion,
  COALESCE(1 - (d_via_m - MIN(d_via_m) OVER ()) / NULLIF(MAX(d_via_m) OVER () - MIN(d_via_m) OVER (), 0), 0)               AS n_via,
  COALESCE((d_amenaza_m - MIN(d_amenaza_m) OVER ()) / NULLIF(MAX(d_amenaza_m) OVER () - MIN(d_amenaza_m) OVER (), 0), 0) AS n_seguridad,
  COALESCE((area_m2     - MIN(area_m2)     OVER ()) / NULLIF(MAX(area_m2)     OVER () - MIN(area_m2)     OVER (), 0), 0) AS n_suelo
FROM analisis.candidatos;

-- ---------------------------------------------------------------------
-- 3. Escenarios de pesos (base + sensibilidad)
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS analisis.escenarios_pesos;
CREATE TABLE analisis.escenarios_pesos (
  escenario   text PRIMARY KEY,
  descripcion text,
  w_deficit numeric, w_poblacion numeric, w_via numeric, w_seguridad numeric, w_suelo numeric,
  CHECK (ROUND(w_deficit + w_poblacion + w_via + w_seguridad + w_suelo, 6) = 1)
);
INSERT INTO analisis.escenarios_pesos VALUES
 ('base',   'Pesos base: 30/25/20/15/10',                              0.30, 0.25, 0.20, 0.15, 0.10),
 ('sens_A', 'Deficit 30->20 y suelo 10->20',                           0.20, 0.25, 0.20, 0.15, 0.20),
 ('sens_B', 'Poblacion 25->35 y via 20->10',                           0.30, 0.35, 0.10, 0.15, 0.10),
 ('iguales','Todos los criterios con el mismo peso (20 %)',            0.20, 0.20, 0.20, 0.20, 0.20);

-- ---------------------------------------------------------------------
-- 4. Puntaje y ranking por escenario
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW analisis.vw_puntajes_escenarios AS
SELECT e.escenario, n.id, n.lotcodigo, n.barrio,
       n.n_deficit*e.w_deficit + n.n_poblacion*e.w_poblacion + n.n_via*e.w_via
         + n.n_seguridad*e.w_seguridad + n.n_suelo*e.w_suelo AS puntaje,
       RANK() OVER (PARTITION BY e.escenario ORDER BY
         n.n_deficit*e.w_deficit + n.n_poblacion*e.w_poblacion + n.n_via*e.w_via
         + n.n_seguridad*e.w_seguridad + n.n_suelo*e.w_suelo DESC) AS ranking
FROM analisis.vw_indicadores_normalizados n
CROSS JOIN analisis.escenarios_pesos e;

-- ---------------------------------------------------------------------
-- 5. VISTA CONSOLIDADA (entregable 5.5): geometria, identificador,
--    5 indicadores normalizados, puntaje total y posicion en el ranking.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW analisis.vw_alternativas_priorizadas AS
SELECT n.id, n.lotcodigo AS identificador, n.barrio, n.area_m2, n.geom,
       ROUND(n.n_deficit::numeric, 4)   AS n_deficit,
       ROUND(n.n_poblacion::numeric, 4) AS n_poblacion,
       ROUND(n.n_via::numeric, 4)       AS n_via,
       ROUND(n.n_seguridad::numeric, 4) AS n_seguridad,
       ROUND(n.n_suelo::numeric, 4)     AS n_suelo,
       ROUND(p.puntaje::numeric, 4)     AS puntaje_total,
       p.ranking
FROM analisis.vw_indicadores_normalizados n
JOIN analisis.vw_puntajes_escenarios p ON p.id = n.id AND p.escenario = 'base';

-- Las 3 mejores alternativas en barrios distintos (evita 3 lotes vecinos)
CREATE OR REPLACE VIEW analisis.vw_top3_alternativas AS
SELECT *
FROM (
  SELECT v.*, ROW_NUMBER() OVER (ORDER BY v.puntaje_total DESC) AS puesto
  FROM (
    SELECT DISTINCT ON (barrio) *
    FROM analisis.vw_alternativas_priorizadas
    WHERE barrio IS NOT NULL
    ORDER BY barrio, puntaje_total DESC
  ) v
) t
WHERE puesto <= 3
ORDER BY puesto;

-- ---------------------------------------------------------------------
-- 6. Resultados y prueba de sensibilidad
-- ---------------------------------------------------------------------

-- 6.1 Top 10 con los pesos base
SELECT ranking, identificador, barrio, ROUND(area_m2::numeric) AS area_m2,
       n_deficit, n_poblacion, n_via, n_seguridad, n_suelo, puntaje_total
FROM analisis.vw_alternativas_priorizadas
ORDER BY ranking
LIMIT 10;

-- 6.2 Las 3 mejores alternativas en barrios distintos
SELECT puesto, identificador, barrio, ROUND(area_m2::numeric) AS area_m2, puntaje_total
FROM analisis.vw_top3_alternativas;

-- 6.3 Sensibilidad: ranking de los 10 mejores del escenario base en todos los escenarios
SELECT b.lotcodigo, b.barrio,
       b.ranking AS rank_base,
       a.ranking AS rank_sens_A,
       c.ranking AS rank_sens_B,
       i.ranking AS rank_iguales,
       GREATEST(b.ranking, a.ranking, c.ranking, i.ranking)
         - LEAST(b.ranking, a.ranking, c.ranking, i.ranking) AS variacion_max
FROM analisis.vw_puntajes_escenarios b
JOIN analisis.vw_puntajes_escenarios a ON a.id = b.id AND a.escenario = 'sens_A'
JOIN analisis.vw_puntajes_escenarios c ON c.id = b.id AND c.escenario = 'sens_B'
JOIN analisis.vw_puntajes_escenarios i ON i.id = b.id AND i.escenario = 'iguales'
WHERE b.escenario = 'base' AND b.ranking <= 10
ORDER BY b.ranking;

-- 6.4 Estabilidad: cuantos de los 10 mejores del escenario base siguen en el top 10
SELECT p.escenario,
       COUNT(*) FILTER (WHERE p.ranking <= 10) AS de_los_top10_base_siguen_en_top10
FROM analisis.vw_puntajes_escenarios p
WHERE p.id IN (SELECT id FROM analisis.vw_puntajes_escenarios WHERE escenario = 'base' AND ranking <= 10)
GROUP BY p.escenario
ORDER BY p.escenario;

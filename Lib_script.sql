-- ============================================================
-- Практическое задание: БД «Библиотеки» (PostgreSQL + PostGIS)
-- Схема libraries, таблица lib_clubs уже создана.
-- Выполнение пунктов 3.1 – 3.3.8
-- ============================================================

-- ============================================================
-- 3.1. ПЕРВИЧНЫЙ КЛЮЧ + SEQUENCE
-- ============================================================

-- Проверка дублей и NULL перед созданием PK
SELECT "data.general.id", count(*) AS cnt
FROM libraries.lib_clubs
GROUP BY "data.general.id"
HAVING count(*) > 1;

SELECT count(*) AS null_ids
FROM libraries.lib_clubs
WHERE "data.general.id" IS NULL;

-- PK на гарантированно уникальную колонку
ALTER TABLE libraries.lib_clubs
    ADD CONSTRAINT lib_clubs_pk PRIMARY KEY ("data.general.id");

-- Sequence для этой колонки
CREATE SEQUENCE IF NOT EXISTS libraries.lib_clubs_id_seq;

ALTER TABLE libraries.lib_clubs
    ALTER COLUMN "data.general.id"
    SET DEFAULT nextval('libraries.lib_clubs_id_seq');

SELECT setval(
    'libraries.lib_clubs_id_seq',
    COALESCE((SELECT MAX("data.general.id") FROM libraries.lib_clubs), 0) + 1,
    false
);

-- ============================================================
-- 3.2. NOT NULL И UNIQUE
-- ============================================================

-- Анализ NULL
SELECT
    count(*) FILTER (WHERE "data.general.name" IS NULL)                AS null_name,
    count(*) FILTER (WHERE "data.general.address.fullAddress" IS NULL) AS null_fulladdress,
    count(*) FILTER (WHERE "data.general.organization.inn" IS NULL)    AS null_inn
FROM libraries.lib_clubs;

-- Анализ дублей по кандидатам на UNIQUE
SELECT "data.general.organization.inn", count(*) AS cnt
FROM libraries.lib_clubs
WHERE "data.general.organization.inn" IS NOT NULL
GROUP BY 1 HAVING count(*) > 1 ORDER BY cnt DESC;

SELECT "data.general.externalIds.culturarf", count(*) AS cnt
FROM libraries.lib_clubs
WHERE "data.general.externalIds.culturarf" IS NOT NULL
GROUP BY 1 HAVING count(*) > 1 ORDER BY cnt DESC;

SELECT "data.general.name", count(*) AS cnt
FROM libraries.lib_clubs
GROUP BY 1 HAVING count(*) > 1 ORDER BY cnt DESC;

-- NOT NULL на двух колонках
ALTER TABLE libraries.lib_clubs
    ALTER COLUMN "data.general.name" SET NOT NULL;

ALTER TABLE libraries.lib_clubs
    ALTER COLUMN "data.general.address.fullAddress" SET NOT NULL;

-- UNIQUE на culturarf (в CSV ИНН дублируется, поэтому не подходит)
ALTER TABLE libraries.lib_clubs
    ADD CONSTRAINT lib_clubs_culturarf_unique
    UNIQUE ("data.general.externalIds.culturarf");

-- ============================================================
-- 3.3.1. УДАЛЯЕМ ВСЁ, КРОМЕ ВОЛОГОДСКОЙ ОБЛАСТИ
-- ============================================================
-- Регион в CSV хранится в data.general.address.fullAddress
-- (префикс вида "обл Вологодская,...")

DELETE FROM libraries.lib_clubs
WHERE "data.general.address.fullAddress" NOT LIKE '%Вологодская%';

SELECT count(*) AS vol_oblast_rows FROM libraries.lib_clubs;

-- ============================================================
-- 3.3.2. POSTGIS + КОЛОНКА geom
-- ============================================================
CREATE EXTENSION IF NOT EXISTS postgis;

ALTER TABLE libraries.lib_clubs
    ADD COLUMN IF NOT EXISTS geom geometry(Point, 4326);

-- ============================================================
-- 3.3.3–3.3.4. ЗАПОЛНЕНИЕ geom ИЗ data.general.address.mapPosition
-- ============================================================
UPDATE libraries.lib_clubs
SET geom = ST_GeomFromGeoJSON("data.general.address.mapPosition"::text)
WHERE "data.general.address.mapPosition" IS NOT NULL
  AND "data.general.address.mapPosition"::text <> ''
  AND jsonb_typeof("data.general.address.mapPosition") = 'object';

-- Проверка
SELECT
    count(*) FILTER (WHERE geom IS NOT NULL) AS with_geom,
    count(*) FILTER (WHERE geom IS NULL)     AS without_geom,
    count(*)                                 AS total
FROM libraries.lib_clubs;

-- ============================================================
-- 3.3.5. ТАБЛИЦА tags (4 колонки + PK + sequence)
-- ============================================================
CREATE TABLE IF NOT EXISTS libraries.tags (
    tag_id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tag_name    varchar(255) NOT NULL,
    tag_sysname varchar(255),
    created_at  timestamptz DEFAULT now(),
    CONSTRAINT tags_name_unique UNIQUE (tag_name)
);

-- ============================================================
-- 3.3.6. ЗАПОЛНЕНИЕ tags УНИКАЛЬНЫМИ ТЕГАМИ ИЗ JSONB-МАССИВА
-- ============================================================
INSERT INTO libraries.tags (tag_name, tag_sysname)
SELECT DISTINCT
       elem ->> 'name'    AS tag_name,
       elem ->> 'sysName' AS tag_sysname
FROM libraries.lib_clubs c
CROSS JOIN LATERAL jsonb_array_elements(c."data.general.tags") AS elem
WHERE c."data.general.tags" IS NOT NULL
  AND jsonb_typeof(c."data.general.tags") = 'array'
  AND elem ->> 'name' IS NOT NULL
ON CONFLICT (tag_name) DO NOTHING;

SELECT count(*) AS total_tags FROM libraries.tags;

-- ============================================================
-- 3.3.7. ПРОМЕЖУТОЧНАЯ ТАБЛИЦА m2m + FK + PK + ЗАПОЛНЕНИЕ
-- ============================================================
CREATE TABLE IF NOT EXISTS libraries.m2m_lib_clubs_tags (
    lib_id bigint NOT NULL
        REFERENCES libraries.lib_clubs("data.general.id") ON DELETE CASCADE,
    tag_id bigint NOT NULL
        REFERENCES libraries.tags(tag_id) ON DELETE CASCADE,
    PRIMARY KEY (lib_id, tag_id)
);

INSERT INTO libraries.m2m_lib_clubs_tags (lib_id, tag_id)
SELECT DISTINCT
       c."data.general.id" AS lib_id,
       t.tag_id
FROM libraries.lib_clubs c
CROSS JOIN LATERAL jsonb_array_elements(c."data.general.tags") AS elem
JOIN libraries.tags t ON t.tag_name = elem ->> 'name'
WHERE c."data.general.tags" IS NOT NULL
  AND jsonb_typeof(c."data.general.tags") = 'array'
ON CONFLICT (lib_id, tag_id) DO NOTHING;

SELECT count(*) AS total_links FROM libraries.m2m_lib_clubs_tags;

-- ============================================================
-- 3.3.8. ИНДЕКСЫ НА m2m
-- ============================================================
CREATE INDEX IF NOT EXISTS idx_m2m_lib_clubs_tags_lib_id
    ON libraries.m2m_lib_clubs_tags (lib_id);

CREATE INDEX IF NOT EXISTS idx_m2m_lib_clubs_tags_tag_id
    ON libraries.m2m_lib_clubs_tags (tag_id);

-- ============================================================
-- ФИНАЛЬНАЯ ПРОВЕРКА
-- ============================================================
SELECT
    (SELECT count(*) FROM libraries.lib_clubs)          AS libs_total,
    (SELECT count(*) FROM libraries.lib_clubs
     WHERE geom IS NOT NULL)                            AS libs_with_geom,
    (SELECT count(*) FROM libraries.tags)               AS tags_total,
    (SELECT count(*) FROM libraries.m2m_lib_clubs_tags) AS links_total;
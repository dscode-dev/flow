-- name: HomeCandidates :many
-- NOT MATERIALIZED allows each bounded branch to use the existing agenda,
-- category, GiST and partial recency indexes. One snapshot/round trip, no N+1.
WITH eligible AS NOT MATERIALIZED (
 SELECT * FROM experiences.discovery WHERE ends_at>sqlc.arg(as_of)::timestamptz
), candidates AS (
 (SELECT 'highlights'::text AS section, d.document, d.category_id, d.starts_at, d.created_at, d.id, 0::float8 AS distance_m
 FROM eligible d WHERE d.starts_at>sqlc.arg(as_of)
 ORDER BY d.starts_at,d.id LIMIT 1)
 UNION ALL
 (SELECT 'live',d.document,d.category_id,d.starts_at,d.created_at,d.id,0::float8
 FROM eligible d WHERE d.starts_at<=sqlc.arg(as_of)
 ORDER BY d.starts_at DESC,d.id DESC LIMIT sqlc.arg(section_limit))
 UNION ALL
 (SELECT 'soon',d.document,d.category_id,d.starts_at,d.created_at,d.id,0::float8
 FROM eligible d WHERE d.starts_at>sqlc.arg(as_of) AND d.starts_at<=sqlc.arg(soon_until)::timestamptz
 ORDER BY d.starts_at,d.id LIMIT sqlc.arg(section_limit))
 UNION ALL
 (SELECT 'nearby',d.document,d.category_id,d.starts_at,d.created_at,d.id,
 ST_Distance(d.point,ST_SetSRID(ST_MakePoint(sqlc.arg(longitude)::float8,sqlc.arg(latitude)::float8),4326)::geography)::float8
 FROM eligible d WHERE sqlc.arg(nearby)::boolean AND
 ST_DWithin(d.point,ST_SetSRID(ST_MakePoint(sqlc.arg(longitude),sqlc.arg(latitude)),4326)::geography,sqlc.arg(radius_m)::float8)
 ORDER BY 7,d.starts_at,d.id LIMIT sqlc.arg(section_limit))
 UNION ALL
 (SELECT 'contextual',d.document,d.category_id,d.starts_at,d.created_at,d.id,0::float8
 FROM eligible d WHERE (sqlc.arg(category_filter)::text='' OR d.category_id=sqlc.arg(category_filter))
 AND (NOT sqlc.arg(nearby)::boolean OR ST_DWithin(d.point,ST_SetSRID(ST_MakePoint(sqlc.arg(longitude),sqlc.arg(latitude)),4326)::geography,sqlc.arg(radius_m)))
 ORDER BY d.starts_at,d.created_at DESC,d.id LIMIT sqlc.arg(section_limit))
 UNION ALL
 (SELECT 'recent',d.document,d.category_id,d.starts_at,d.created_at,d.id,0::float8
 FROM eligible d ORDER BY d.created_at DESC,d.id DESC LIMIT sqlc.arg(section_limit))
)
SELECT c.section::text,c.document::jsonb,cat.name::text AS category_name,c.distance_m::float8,
 c.starts_at,c.created_at,c.id FROM candidates c
 JOIN experiences.categories cat ON cat.id=c.category_id;

-- name: HomeCategories :many
SELECT id,name,sort_order FROM experiences.categories WHERE enabled ORDER BY sort_order,id LIMIT 100;

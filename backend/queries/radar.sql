-- name: RadarExperiences :many
SELECT jsonb_build_object(
 'id',d.id,'title',d.document->>'title','category_id',d.category_id,'category_name',c.name,
 'location',d.document->'location','starts_at',d.starts_at,'ends_at',d.ends_at,
 'timezone',d.document->>'timezone','venue_name',d.document->>'venue_name',
 'cover_media_id',d.document->'cover_media_id','version',d.document->'version',
 'phase',CASE WHEN d.starts_at<=sqlc.arg(as_of)::timestamptz THEN 'LIVE' ELSE 'UPCOMING' END,
 'external_ticket',(d.document->>'external_ticket_url') IS NOT NULL
)::jsonb AS marker
FROM experiences.discovery d JOIN experiences.categories c ON c.id=d.category_id
WHERE d.ends_at>sqlc.arg(as_of)::timestamptz
 AND ((NOT sqlc.arg(crosses)::boolean AND ST_Intersects(d.point::geometry,ST_MakeEnvelope(sqlc.arg(west)::float8,sqlc.arg(south)::float8,sqlc.arg(east)::float8,sqlc.arg(north)::float8,4326)))
 OR (sqlc.arg(crosses) AND (ST_Intersects(d.point::geometry,ST_MakeEnvelope(sqlc.arg(west),sqlc.arg(south),180,sqlc.arg(north),4326))
 OR ST_Intersects(d.point::geometry,ST_MakeEnvelope(-180,sqlc.arg(south),sqlc.arg(east),sqlc.arg(north),4326)))))
 AND (sqlc.arg(category_filter)::text='' OR d.category_id=sqlc.arg(category_filter))
 AND (sqlc.arg(phase_filter)::text='' OR (sqlc.arg(phase_filter)='LIVE' AND d.starts_at<=sqlc.arg(as_of)) OR (sqlc.arg(phase_filter)='UPCOMING' AND d.starts_at>sqlc.arg(as_of)))
 AND (NOT sqlc.arg(period)::boolean OR (d.starts_at<sqlc.arg(until_time)::timestamptz AND d.ends_at>sqlc.arg(from_time)::timestamptz))
 AND (NOT sqlc.arg(nearby)::boolean OR ST_DWithin(d.point,ST_SetSRID(ST_MakePoint(sqlc.arg(longitude)::float8,sqlc.arg(latitude)::float8),4326)::geography,sqlc.arg(radius_m)::float8))
ORDER BY d.starts_at,d.id LIMIT sqlc.arg(result_limit);

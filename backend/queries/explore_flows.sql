-- name: ExploreExperiences :many
SELECT d.document::jsonb AS document FROM experiences.discovery d
JOIN experiences.experiences e ON e.id=d.id
WHERE d.ends_at>sqlc.arg(as_of)::timestamptz
AND NOT EXISTS(SELECT FROM participation.members b WHERE b.experience_id=d.id AND b.user_id=sqlc.arg(viewer)::uuid AND b.blocked)
AND (sqlc.arg(search)::text='' OR e.search_vector @@ websearch_to_tsquery('portuguese',experiences.search_normalize(sqlc.arg(search))))
AND (sqlc.arg(category_filter)::text='' OR d.category_id=sqlc.arg(category_filter))
AND (sqlc.arg(phase_filter)::text='' OR (sqlc.arg(phase_filter)='LIVE' AND d.starts_at<=sqlc.arg(as_of)) OR (sqlc.arg(phase_filter)='UPCOMING' AND d.starts_at>sqlc.arg(as_of)))
AND (NOT sqlc.arg(period)::boolean OR (d.starts_at<sqlc.arg(until_time)::timestamptz AND d.ends_at>sqlc.arg(from_time)::timestamptz))
AND (NOT sqlc.arg(nearby)::boolean OR ST_DWithin(d.point,ST_SetSRID(ST_MakePoint(sqlc.arg(longitude)::float8,sqlc.arg(latitude)::float8),4326)::geography,sqlc.arg(radius_m)::float8))
AND (d.starts_at,d.id)>(sqlc.arg(after_time)::timestamptz,sqlc.arg(after_id)::uuid)
ORDER BY d.starts_at,d.id LIMIT sqlc.arg(page_limit);

-- name: ListFlows :many
SELECT f.document::jsonb AS document,f.presentation_version,f.image_kind,f.image_asset_id,f.video_asset_id,f.duration_ms,f.media_width,f.media_height,
 CASE WHEN f.starts_at<=sqlc.arg(snapshot)::timestamptz THEN 0 ELSE 1 END::integer AS phase_rank
FROM experiences.flow_discovery f
WHERE f.ends_at>sqlc.arg(as_of)::timestamptz AND f.starts_at<=sqlc.arg(window_end)::timestamptz
AND NOT EXISTS(SELECT FROM participation.members b WHERE b.experience_id=f.id AND b.user_id=sqlc.arg(viewer)::uuid AND b.blocked)
AND (sqlc.arg(category_filter)::text='' OR f.category_id=sqlc.arg(category_filter))
AND (NOT sqlc.arg(nearby)::boolean OR ST_DWithin(f.point,ST_SetSRID(ST_MakePoint(sqlc.arg(longitude)::float8,sqlc.arg(latitude)::float8),4326)::geography,sqlc.arg(radius_m)::float8))
AND (CASE WHEN f.starts_at<=sqlc.arg(snapshot) THEN 0 ELSE 1 END,f.starts_at,f.id)>(sqlc.arg(after_rank)::integer,sqlc.arg(after_time)::timestamptz,sqlc.arg(after_id)::uuid)
ORDER BY phase_rank,f.starts_at,f.id LIMIT sqlc.arg(page_limit);

-- name: GetEligibleFlow :one
SELECT f.document::jsonb AS document,f.presentation_version,f.image_kind,f.image_asset_id,f.video_asset_id,f.duration_ms,f.media_width,f.media_height
FROM experiences.flow_discovery f WHERE f.id=sqlc.arg(experience_id) AND f.ends_at>sqlc.arg(as_of) AND f.starts_at<=sqlc.arg(window_end)
AND NOT EXISTS(SELECT FROM participation.members b WHERE b.experience_id=f.id AND b.user_id=sqlc.arg(viewer)::uuid AND b.blocked);

-- name: GetFlowPresentation :one
SELECT * FROM experiences.flow_presentations WHERE experience_id=$1;
-- name: SaveFlowPresentation :exec
INSERT INTO experiences.flow_presentations(experience_id,enabled,unlisted_consent_at,unlisted_consent_actor,image_asset_id,video_asset_id,version)
VALUES($1,$2,$3,$4,$5,$6,$7) ON CONFLICT(experience_id) DO UPDATE SET enabled=excluded.enabled,
unlisted_consent_at=excluded.unlisted_consent_at,unlisted_consent_actor=excluded.unlisted_consent_actor,
image_asset_id=excluded.image_asset_id,video_asset_id=excluded.video_asset_id,version=excluded.version,updated_at=now();
-- name: InsertFlowAudit :exec
INSERT INTO experiences.flow_audit(id,experience_id,actor_user_id,action,version,request_id,details) VALUES($1,$2,$3,$4,$5,$6,$7);
-- name: FlowMediaSessionActive :one
SELECT EXISTS(SELECT FROM identity.sessions s JOIN identity.users u ON u.id=s.user_id
 WHERE s.id=$1 AND s.user_id=$2 AND s.revoked_at IS NULL AND s.expires_at>now() AND u.status='active');

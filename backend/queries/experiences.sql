-- name: ListExperienceCategories :many
SELECT id,name,sort_order FROM experiences.categories WHERE enabled ORDER BY sort_order,id;

-- name: EnabledExperienceCategory :one
SELECT id FROM experiences.categories WHERE id=$1 AND enabled FOR SHARE;

-- name: InsertExperience :exec
INSERT INTO experiences.experiences(id,creator_user_id) VALUES($1,$2);

-- name: GetExperience :one
SELECT document::jsonb AS document FROM experiences.documents WHERE id=$1;

-- name: LockExperience :one
SELECT id FROM experiences.experiences WHERE id=$1 FOR UPDATE;

-- name: SaveExperience :exec
UPDATE experiences.experiences SET
 title=sqlc.arg(data)::jsonb->>'title', description=sqlc.arg(data)::jsonb->>'description',
 category_id=sqlc.arg(data)::jsonb->>'category_id', visibility=sqlc.arg(data)::jsonb->>'visibility',
 status=sqlc.arg(data)::jsonb->>'status', starts_at=(sqlc.arg(data)::jsonb->>'starts_at')::timestamptz,
 ends_at=(sqlc.arg(data)::jsonb->>'ends_at')::timestamptz, timezone=sqlc.arg(data)::jsonb->>'timezone',
 point=CASE WHEN sqlc.arg(data)::jsonb->'location' IS NULL OR sqlc.arg(data)::jsonb->'location'='null'::jsonb THEN NULL ELSE
 ST_SetSRID(ST_MakePoint((sqlc.arg(data)::jsonb->'location'->>'longitude')::float8,(sqlc.arg(data)::jsonb->'location'->>'latitude')::float8),4326)::geography END,
 venue_name=sqlc.arg(data)::jsonb->>'venue_name', address=sqlc.arg(data)::jsonb->>'address',
 capacity=(sqlc.arg(data)::jsonb->>'capacity')::integer, external_ticket_url=sqlc.arg(data)::jsonb->>'external_ticket_url',
 cover_media_id=(sqlc.arg(data)::jsonb->>'cover_media_id')::uuid,
 published_at=(sqlc.arg(data)::jsonb->>'published_at')::timestamptz,
 cancelled_at=(sqlc.arg(data)::jsonb->>'cancelled_at')::timestamptz,
 archived_at=(sqlc.arg(data)::jsonb->>'archived_at')::timestamptz,
 updated_at=clock_timestamp(), version=sqlc.arg(next_version)
WHERE id=sqlc.arg(id);

-- name: ExperienceIdempotency :one
SELECT request_hash,response FROM experiences.idempotency WHERE creator_user_id=$1 AND key=$2 AND expires_at>now();

-- name: DeleteExpiredExperienceKey :exec
DELETE FROM experiences.idempotency WHERE creator_user_id=$1 AND key=$2 AND expires_at<=now();

-- name: InsertExperienceIdempotency :exec
INSERT INTO experiences.idempotency(creator_user_id,key,request_hash,experience_id,response) VALUES($1,$2,$3,$4,$5);

-- name: ExperienceRate :one
INSERT INTO experiences.rate_limits(owner_user_id,operation,window_start,count) VALUES($1,$2,date_trunc('day',now() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC',1)
ON CONFLICT(owner_user_id,operation,window_start) DO UPDATE SET count=experiences.rate_limits.count+1 RETURNING count;

-- name: ExperiencePublishingRestricted :one
SELECT EXISTS(SELECT FROM experiences.publishing_restrictions WHERE creator_user_id=$1 AND blocked_until>now());

-- name: ExperienceDraftCount :one
SELECT count(*) FROM experiences.experiences WHERE creator_user_id=$1 AND status='DRAFT';

-- name: InsertExperienceAudit :exec
INSERT INTO experiences.audit_events(id,experience_id,actor_user_id,action,version,request_id) VALUES($1,$2,$3,$4,$5,$6);

-- name: ListOwnExperiences :many
SELECT document::jsonb AS document FROM experiences.documents
WHERE creator_user_id=sqlc.arg(owner)
 AND (sqlc.arg(status_filter)::text='' OR status=sqlc.arg(status_filter))
 AND (created_at,id)<(sqlc.arg(before_time)::timestamptz,sqlc.arg(before_id)::uuid)
ORDER BY created_at DESC,id DESC LIMIT sqlc.arg(page_limit);

-- name: DiscoverExperiences :many
SELECT d.document::jsonb AS document FROM experiences.discovery d
WHERE d.ends_at>sqlc.arg(as_of)::timestamptz
 AND (sqlc.arg(category_filter)::text='' OR d.category_id=sqlc.arg(category_filter))
 AND (sqlc.arg(phase_filter)::text='' OR (sqlc.arg(phase_filter)='LIVE' AND d.starts_at<=sqlc.arg(as_of)) OR (sqlc.arg(phase_filter)='UPCOMING' AND d.starts_at>sqlc.arg(as_of)))
 AND (d.starts_at,d.id)>(sqlc.arg(after_time)::timestamptz,sqlc.arg(after_id)::uuid)
 AND (NOT sqlc.arg(nearby)::boolean OR ST_DWithin(d.point,ST_SetSRID(ST_MakePoint(sqlc.arg(longitude)::float8,sqlc.arg(latitude)::float8),4326)::geography,sqlc.arg(radius_m)::float8))
ORDER BY d.starts_at,d.id LIMIT sqlc.arg(page_limit);

-- name: CleanupExperienceTechnical :exec
DELETE FROM experiences.idempotency WHERE expires_at<=now();

-- name: CleanupExperienceRates :exec
DELETE FROM experiences.rate_limits WHERE window_start<now()-interval '2 days';

-- name: CleanupExperienceAudit :exec
DELETE FROM experiences.audit_events WHERE created_at<now()-interval '180 days';

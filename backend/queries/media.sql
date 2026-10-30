-- name: InsertMediaUpload :exec
INSERT INTO media.uploads(id,owner_user_id,idempotency_key,request_hash,content_type,size_bytes,staging_key,object_key,expires_at)
 VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9);

-- name: FindMediaUploadKey :one
SELECT * FROM media.uploads WHERE owner_user_id=$1 AND idempotency_key=$2 FOR UPDATE;

-- name: LockMediaUpload :one
SELECT * FROM media.uploads WHERE id=$1 FOR UPDATE;

-- name: GetMediaUpload :one
SELECT * FROM media.uploads WHERE id=$1;

-- name: ReadyMediaUpload :exec
UPDATE media.uploads SET status='READY',verified_size=$2,width=$3,height=$4,sha256=$5,confirmed_at=now() WHERE id=$1;

-- name: RejectMediaUpload :exec
UPDATE media.uploads SET status='REJECTED' WHERE id=$1;

-- name: SetMediaBinding :exec
INSERT INTO media.bindings(experience_id,media_id,owner_user_id) VALUES($1,$2,$3)
ON CONFLICT(experience_id) DO UPDATE SET media_id=excluded.media_id,owner_user_id=excluded.owner_user_id,bound_at=now();

-- name: RemoveMediaBinding :exec
DELETE FROM media.bindings WHERE experience_id=$1;

-- name: InsertMediaAudit :exec
INSERT INTO media.audit_events(id,media_id,actor_user_id,action,request_id) VALUES($1,$2,$3,$4,$5);

-- name: MediaCleanupCandidates :many
SELECT * FROM media.uploads u WHERE (expires_at<now()-interval '1 hour' AND staging_cleaned_at IS NULL)
 OR (status IN ('UPLOADING','REJECTED','READY') AND created_at<now()-interval '24 hours' AND NOT EXISTS(SELECT FROM media.bindings b WHERE b.media_id=u.id))
ORDER BY expires_at,id LIMIT 100 FOR UPDATE SKIP LOCKED;

-- name: MediaStagingCleaned :exec
UPDATE media.uploads SET staging_cleaned_at=now() WHERE id=$1;

-- name: DeleteMediaUpload :exec
UPDATE media.uploads SET status='DELETED',deleted_at=now() WHERE id=$1;

-- name: MediaIsBound :one
SELECT EXISTS(SELECT FROM media.bindings WHERE media_id=$1);

-- name: MediaUploadRate :one
INSERT INTO media.rate_limits(owner_user_id,window_start,count) VALUES($1,date_trunc('day',now() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC',1)
ON CONFLICT(owner_user_id,window_start) DO UPDATE SET count=media.rate_limits.count+1 RETURNING count;

-- name: CleanupMediaRates :exec
DELETE FROM media.rate_limits WHERE window_start<now()-interval '2 days';

-- name: CleanupMediaTombstones :exec
DELETE FROM media.uploads u WHERE status='DELETED' AND deleted_at<now()-interval '30 days'
 AND NOT EXISTS(SELECT FROM media.bindings b WHERE b.media_id=u.id);

-- name: CleanupMediaAudit :exec
DELETE FROM media.audit_events WHERE created_at<now()-interval '180 days';

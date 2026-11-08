-- name: FindFlowAssetKey :one
SELECT * FROM media.flow_assets WHERE owner_user_id=$1 AND idempotency_key=$2;
-- name: GetFlowAsset :one
SELECT * FROM media.flow_assets WHERE id=$1;
-- name: LockFlowAsset :one
SELECT * FROM media.flow_assets WHERE id=$1 FOR UPDATE;
-- name: InsertFlowAsset :exec
INSERT INTO media.flow_assets(id,experience_id,owner_user_id,idempotency_key,request_hash,content_type,size_bytes,staging_key,object_key,poster_key,expires_at)
VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11);
-- name: QueueFlowAsset :exec
UPDATE media.flow_assets SET status='PROCESSING',confirmed_at=now() WHERE id=$1;
-- name: ClaimFlowAsset :one
UPDATE media.flow_assets SET lease_until=now()+interval '100 seconds',lease_id=sqlc.arg(lease_id),attempts=attempts+1
WHERE id=(SELECT id FROM media.flow_assets WHERE status='PROCESSING' AND (lease_until IS NULL OR lease_until<now()) ORDER BY created_at,id FOR UPDATE SKIP LOCKED LIMIT 1)
RETURNING *;
-- name: ReadyFlowAsset :execrows
UPDATE media.flow_assets SET status='READY',width=$3,height=$4,duration_ms=$5,verified_size=$6,sha256=$7,processed_at=now(),lease_until=NULL
WHERE id=$1 AND lease_id=$2 AND status='PROCESSING';
-- name: FailFlowAsset :exec
UPDATE media.flow_assets SET status='FAILED',failure_code=$3,processed_at=now(),lease_until=NULL
WHERE id=$1 AND lease_id=$2 AND status='PROCESSING';
-- name: FlowAssetCleanupCandidates :many
SELECT a.* FROM media.flow_assets a WHERE
 (a.expires_at<now()-interval '1 hour' AND a.staging_cleaned_at IS NULL AND a.status<>'PROCESSING') OR
 (a.created_at<now()-interval '24 hours' AND a.status NOT IN ('PROCESSING','DELETED')
 AND NOT EXISTS(SELECT FROM experiences.flow_presentations p WHERE p.image_asset_id=a.id OR p.video_asset_id=a.id))
ORDER BY a.created_at,a.id LIMIT 50 FOR UPDATE SKIP LOCKED;
-- name: FlowAssetStagingCleaned :exec
UPDATE media.flow_assets SET staging_cleaned_at=now() WHERE id=$1;
-- name: FlowAssetIsBound :one
SELECT EXISTS(SELECT FROM experiences.flow_presentations WHERE image_asset_id=$1 OR video_asset_id=$1);
-- name: DeleteFlowAsset :exec
UPDATE media.flow_assets SET status='DELETED',deleted_at=now() WHERE id=$1;
-- name: DeleteFlowTombstones :exec
DELETE FROM media.flow_assets a WHERE status='DELETED' AND staging_cleaned_at IS NOT NULL AND deleted_at<now()-interval '7 days'
AND NOT EXISTS(SELECT FROM experiences.flow_presentations p WHERE p.image_asset_id=a.id OR p.video_asset_id=a.id);
-- name: CleanupFlowAudit :exec
DELETE FROM experiences.flow_audit WHERE created_at<now()-interval '180 days';

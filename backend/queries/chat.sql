-- name: ChatSnapshot :one
SELECT event_space.can_read($1::uuid,$2::uuid)::boolean AS can_read,event_space.can_write($1,$2)::boolean AS can_write,event_space.can_moderate($1,$2)::boolean AS can_moderate,coalesce((SELECT sequence FROM chat.rooms WHERE experience_id=$1),0)::bigint AS head,(SELECT version FROM chat.policy_clock WHERE id)::bigint AS policy;
-- name: ChatNext :one
INSERT INTO chat.rooms(experience_id,sequence) VALUES($1,1) ON CONFLICT(experience_id) DO UPDATE SET sequence=chat.rooms.sequence+1 RETURNING sequence;
-- name: ChatFindClient :one
SELECT id,request_hash FROM chat.messages WHERE experience_id=$1 AND author_user_id=$2 AND client_message_id=$3;
-- name: ChatInsert :exec
INSERT INTO chat.messages(id,experience_id,author_user_id,client_message_id,request_hash,body,sequence) VALUES($1,$2,$3,$4,$5,$6,$7);
-- name: ChatChange :exec
INSERT INTO chat.changes(experience_id,sequence,message_id) VALUES($1,$2,$3);
-- name: ChatDocument :one
SELECT chat.document($1::uuid,$2::uuid)::jsonb AS document;
-- name: ChatHistory :many
SELECT m.sequence,chat.document(m.id,sqlc.arg(viewer)::uuid)::jsonb AS document FROM chat.messages m WHERE m.experience_id=sqlc.arg(experience_id)::uuid AND m.sequence<sqlc.arg(before_seq)::bigint AND m.sequence<=sqlc.arg(snapshot)::bigint AND event_space.can_read(m.experience_id,sqlc.arg(viewer)) ORDER BY m.sequence DESC LIMIT sqlc.arg(page_limit);
-- name: ChatChanges :many
SELECT c.sequence,chat.document(c.message_id,sqlc.arg(viewer)::uuid)::jsonb AS document FROM chat.changes c WHERE c.experience_id=sqlc.arg(experience_id)::uuid AND c.sequence>sqlc.arg(after_seq)::bigint AND c.sequence<=sqlc.arg(snapshot)::bigint AND event_space.can_read(c.experience_id,sqlc.arg(viewer)) ORDER BY c.sequence LIMIT sqlc.arg(page_limit);
-- name: ChatLockMessage :one
SELECT * FROM chat.messages WHERE id=$1 FOR UPDATE;
-- name: ChatRemove :exec
UPDATE chat.messages SET body=NULL,deleted_at=coalesce(deleted_at,now()) WHERE id=$1;
-- name: ChatModerate :exec
UPDATE chat.messages SET moderation_status=$2 WHERE id=$1;
-- name: ChatConnectionCount :one
SELECT count(*)::integer FROM chat.connections WHERE expires_at>now() AND (user_id=$1 OR experience_id=$2);
-- name: ChatUserConnections :one
SELECT count(*)::integer FROM chat.connections WHERE expires_at>now() AND user_id=$1;
-- name: ChatLease :exec
INSERT INTO chat.connections(id,user_id,session_id,experience_id,expires_at) VALUES($1,$2,$3,$4,now()+interval '15 seconds') ON CONFLICT(id) DO UPDATE SET expires_at=excluded.expires_at;
-- name: ChatDisconnect :exec
DELETE FROM chat.connections WHERE id=$1;
-- name: ChatCleanup :exec
WITH changes AS(DELETE FROM chat.changes WHERE (experience_id,sequence) IN(SELECT experience_id,sequence FROM chat.changes WHERE created_at<now()-interval '180 days' LIMIT 500)),
records AS(DELETE FROM chat.messages WHERE id IN(SELECT m.id FROM chat.messages m WHERE m.created_at<now()-interval '180 days' AND NOT EXISTS(SELECT FROM chat.changes c WHERE c.message_id=m.id) LIMIT 500)),
leases AS(DELETE FROM chat.connections WHERE id IN(SELECT id FROM chat.connections WHERE expires_at<now() LIMIT 500)) UPDATE chat.messages SET body=NULL,deleted_at=coalesce(deleted_at,now()) WHERE id IN(SELECT id FROM chat.messages WHERE body IS NOT NULL AND created_at<now()-interval '90 days' LIMIT 500);
-- name: ChatOperationalMessages :many
SELECT jsonb_build_object('id',id,'experience_id',experience_id,'sequence',sequence::text,'body',body,'deleted_at',deleted_at,'moderation_status',moderation_status)::jsonb AS document FROM chat.messages WHERE experience_id=$1 ORDER BY sequence DESC LIMIT 50;

-- name: ChatMessageSpace :one
SELECT experience_id FROM chat.messages WHERE id=$1;

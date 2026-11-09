-- name: SocialActive :one
SELECT social.active($1::uuid)::boolean;
-- name: SocialConnected :one
SELECT social.connected($1::uuid,$2::uuid)::boolean;
-- name: SocialPairLock :exec
SELECT pg_advisory_xact_lock(hashtextextended(least($1::text,$2::text)||greatest($1::text,$2::text),707));
-- name: SocialExperienceEligible :one
SELECT social.experience_eligible($1::uuid,$2::uuid,$3::uuid)::boolean;
-- name: SocialPost :one
SELECT social.post_document($1::uuid,$2::uuid)::jsonb AS document;
-- name: SocialFeed :many
SELECT p.created_at,p.id,social.post_document(p.id,sqlc.arg(viewer)::uuid)::jsonb AS document FROM social.posts p
WHERE p.deleted_at IS NULL AND p.moderation_status='VISIBLE' AND p.created_at<=sqlc.arg(snapshot)::timestamptz
AND (p.created_at,p.id)<(sqlc.arg(after_time)::timestamptz,sqlc.arg(after_id)::uuid)
AND (sqlc.arg(profile)::uuid IS NULL OR p.author_user_id=sqlc.arg(profile))
AND (sqlc.arg(mode)::text<>'DISCOVER' OR p.visibility='PUBLIC')
AND (sqlc.arg(mode)::text<>'FOLLOWING' OR EXISTS(SELECT FROM social.follows f WHERE f.follower_id=sqlc.arg(viewer) AND f.followed_id=p.author_user_id))
AND social.can_read(p.id,sqlc.arg(viewer)) ORDER BY p.created_at DESC,p.id DESC LIMIT sqlc.arg(page_limit);
-- name: SocialLockPost :one
SELECT * FROM social.posts WHERE id=$1 FOR UPDATE;
-- name: SocialInsertPost :exec
INSERT INTO social.posts(id,author_user_id,experience_id,context,visibility,body) VALUES($1,$2,$3,$4,$5,$6);
-- name: SocialEditPost :exec
UPDATE social.posts SET body=$2,edited_at=now(),updated_at=now(),version=version+1 WHERE id=$1;
-- name: SocialDeletePost :exec
UPDATE social.posts SET deleted_at=now(),body='',updated_at=now(),version=version+1 WHERE id=$1 AND deleted_at IS NULL;
-- name: SocialBindMedia :exec
INSERT INTO social.post_media(post_id,asset_id,position) VALUES($1,$2,$3);
-- name: SocialLike :execrows
INSERT INTO social.likes(post_id,user_id) VALUES($1,$2) ON CONFLICT DO NOTHING;
-- name: SocialUnlike :execrows
DELETE FROM social.likes WHERE post_id=$1 AND user_id=$2;
-- name: SocialComment :exec
INSERT INTO social.comments(id,post_id,author_user_id,body) VALUES($1,$2,$3,$4);
-- name: SocialLockComment :one
SELECT * FROM social.comments WHERE id=$1 FOR UPDATE;
-- name: SocialDeleteComment :exec
UPDATE social.comments SET deleted_at=now(),body='' WHERE id=$1 AND deleted_at IS NULL;
-- name: SocialComments :many
SELECT c.id,c.created_at,jsonb_build_object('id',c.id,'post_id',c.post_id,'author',social.person(c.author_user_id),'body',c.body,'created_at',c.created_at,'can_delete',c.author_user_id=sqlc.arg(viewer)::uuid OR p.author_user_id=sqlc.arg(viewer))::jsonb AS document
FROM social.comments c JOIN social.posts p ON p.id=c.post_id WHERE c.post_id=sqlc.arg(post_id) AND social.can_read(c.post_id,sqlc.arg(viewer))
AND c.deleted_at IS NULL AND c.moderation_status='VISIBLE' AND social.connected(c.author_user_id,sqlc.arg(viewer)) AND social.connected(c.author_user_id,p.author_user_id)
AND c.created_at<=sqlc.arg(snapshot)::timestamptz AND (c.created_at,c.id)<(sqlc.arg(after_time)::timestamptz,sqlc.arg(after_id)::uuid)
ORDER BY c.created_at DESC,c.id DESC LIMIT sqlc.arg(page_limit);
-- name: SocialFollow :execrows
INSERT INTO social.follows(follower_id,followed_id) VALUES($1,$2) ON CONFLICT DO NOTHING;
-- name: SocialUnfollow :execrows
DELETE FROM social.follows WHERE follower_id=$1 AND followed_id=$2;
-- name: SocialBlock :execrows
INSERT INTO social.blocks(blocker_id,blocked_id) VALUES($1,$2) ON CONFLICT DO NOTHING;
-- name: SocialUnblock :execrows
DELETE FROM social.blocks WHERE blocker_id=$1 AND blocked_id=$2;
-- name: SocialSeverFollows :exec
DELETE FROM social.follows WHERE (follower_id=$1 AND followed_id=$2) OR (follower_id=$2 AND followed_id=$1);
-- name: SocialOwnBlock :one
SELECT EXISTS(SELECT FROM social.blocks WHERE blocker_id=$1 AND blocked_id=$2);
-- name: SocialProfile :one
SELECT (social.person(sqlc.arg(profile)::uuid) || jsonb_build_object(
'is_self',sqlc.arg(profile)=sqlc.arg(viewer)::uuid,'following',EXISTS(SELECT FROM social.follows WHERE follower_id=sqlc.arg(viewer) AND followed_id=sqlc.arg(profile)),
'follows_you',EXISTS(SELECT FROM social.follows WHERE follower_id=sqlc.arg(profile) AND followed_id=sqlc.arg(viewer)),
'post_count',(SELECT count(*) FROM social.posts p WHERE p.author_user_id=sqlc.arg(profile) AND social.can_read(p.id,sqlc.arg(viewer))),
'follower_count',(SELECT count(*) FROM social.follows f WHERE f.followed_id=sqlc.arg(profile) AND social.connected(f.follower_id,sqlc.arg(viewer)) AND social.connected(f.follower_id,sqlc.arg(profile))),
'following_count',(SELECT count(*) FROM social.follows f WHERE f.follower_id=sqlc.arg(profile) AND social.connected(f.followed_id,sqlc.arg(viewer)) AND social.connected(f.followed_id,sqlc.arg(profile)))))::jsonb AS document
WHERE social.connected(sqlc.arg(profile),sqlc.arg(viewer));
-- name: SocialPeople :many
SELECT f.created_at,CASE WHEN sqlc.arg(section)::text='FOLLOWERS' THEN f.follower_id ELSE f.followed_id END::uuid AS id,
social.person(CASE WHEN sqlc.arg(section)::text='FOLLOWERS' THEN f.follower_id ELSE f.followed_id END)::jsonb AS document
FROM social.follows f WHERE ((sqlc.arg(section)='FOLLOWERS' AND f.followed_id=sqlc.arg(profile)::uuid) OR (sqlc.arg(section)='FOLLOWING' AND f.follower_id=sqlc.arg(profile)))
AND social.connected(f.follower_id,f.followed_id) AND social.connected(f.follower_id,sqlc.arg(viewer)::uuid) AND social.connected(f.followed_id,sqlc.arg(viewer))
AND f.created_at<=sqlc.arg(snapshot)::timestamptz AND (f.created_at,CASE WHEN sqlc.arg(section)='FOLLOWERS' THEN f.follower_id ELSE f.followed_id END)<(sqlc.arg(after_time)::timestamptz,sqlc.arg(after_id)::uuid)
ORDER BY f.created_at DESC,id DESC LIMIT sqlc.arg(page_limit);
-- name: SocialBlocks :many
SELECT b.created_at,b.blocked_id AS id,jsonb_build_object('user_id',b.blocked_id)::jsonb AS document FROM social.blocks b WHERE b.blocker_id=sqlc.arg(viewer)::uuid
AND b.created_at<=sqlc.arg(snapshot)::timestamptz AND (b.created_at,b.blocked_id)<(sqlc.arg(after_time)::timestamptz,sqlc.arg(after_id)::uuid)
ORDER BY b.created_at DESC,b.blocked_id DESC LIMIT sqlc.arg(page_limit);
-- name: SocialReport :execrows
INSERT INTO social.reports(id,reporter_user_id,target_type,target_id,reason) VALUES($1,$2,$3,$4,$5) ON CONFLICT DO NOTHING;
-- name: SocialAudit :exec
INSERT INTO social.audit(id,actor,resource_id,action,request_id,details) VALUES($1,$2,$3,$4,$5,$6);
-- name: SocialReceipt :one
SELECT * FROM social.receipts WHERE actor_user_id=$1 AND key=$2 AND expires_at>now();
-- name: SocialSaveReceipt :exec
INSERT INTO social.receipts(actor_user_id,key,request_hash,response) VALUES($1,$2,$3,$4) ON CONFLICT(actor_user_id,key) DO UPDATE SET request_hash=excluded.request_hash,response=excluded.response,expires_at=excluded.expires_at;
-- name: SocialRate :one
INSERT INTO social.rate_limits(user_id,window_start,count) VALUES($1,date_trunc('minute',now()),1) ON CONFLICT(user_id,window_start) DO UPDATE SET count=social.rate_limits.count+1 RETURNING count;
-- name: SocialModeratePost :exec
UPDATE social.posts SET moderation_status=$2,updated_at=now(),version=version+1 WHERE id=$1;
-- name: SocialModerateComment :exec
UPDATE social.comments SET moderation_status=$2 WHERE id=$1;
-- name: SocialRestrict :exec
INSERT INTO social.restrictions(user_id,restricted) VALUES($1,$2) ON CONFLICT(user_id) DO UPDATE SET restricted=$2,updated_at=now();
-- name: SocialResolveReport :execrows
UPDATE social.reports SET status='RESOLVED',resolved_at=now() WHERE id=$1 AND status='OPEN';
-- name: SocialCleanup :exec
WITH a AS (DELETE FROM social.receipts WHERE (actor_user_id,key) IN (SELECT actor_user_id,key FROM social.receipts WHERE expires_at<now() LIMIT 500)),
b AS (DELETE FROM social.rate_limits WHERE (user_id,window_start) IN (SELECT user_id,window_start FROM social.rate_limits WHERE window_start<now()-interval '2 days' LIMIT 500)),
c AS (DELETE FROM social.audit WHERE id IN (SELECT id FROM social.audit WHERE created_at<now()-interval '180 days' LIMIT 500)),
d AS (DELETE FROM social.reports WHERE id IN (SELECT id FROM social.reports WHERE created_at<now()-interval '180 days' LIMIT 500)),
e AS (DELETE FROM social.comments WHERE id IN (SELECT id FROM social.comments WHERE deleted_at<now()-interval '7 days' LIMIT 500))
DELETE FROM social.posts WHERE id IN (SELECT p.id FROM social.posts p WHERE p.deleted_at<now()-interval '7 days' AND NOT EXISTS(SELECT FROM social.post_media m JOIN media.flow_assets a ON a.id=m.asset_id WHERE m.post_id=p.id AND a.status<>'DELETED') LIMIT 500);
-- name: SocialOperationalPosts :many
SELECT jsonb_build_object('id',p.id,'author_user_id',p.author_user_id,'body',p.body,'deleted_at',p.deleted_at,'moderation_status',p.moderation_status,'version',p.version)::jsonb AS document FROM social.posts p
WHERE (sqlc.arg(post_id)::uuid IS NULL OR p.id=sqlc.arg(post_id)) AND (sqlc.arg(author)::uuid IS NULL OR p.author_user_id=sqlc.arg(author)) ORDER BY p.created_at DESC,p.id DESC LIMIT 50;
-- name: SocialOperationalReports :many
SELECT jsonb_build_object('id',id,'reporter_user_id',reporter_user_id,'target_type',target_type,'target_id',target_id,'reason',reason,'status',status,'created_at',created_at)::jsonb AS document FROM social.reports WHERE status='OPEN' ORDER BY created_at,id LIMIT 50;
-- name: SocialExperienceOptions :many
SELECT e.id,e.created_at,jsonb_build_object('id',e.id,'title',e.title)::jsonb AS document FROM experiences.experiences e
WHERE e.id IN (SELECT id FROM experiences.experiences WHERE creator_user_id=sqlc.arg(viewer)::uuid UNION SELECT experience_id FROM participation.members WHERE user_id=sqlc.arg(viewer) AND state='CONFIRMED' AND NOT blocked)
AND social.experience_eligible(e.id,sqlc.arg(viewer),sqlc.arg(viewer))
AND e.created_at<=sqlc.arg(snapshot)::timestamptz AND (e.created_at,e.id)<(sqlc.arg(after_time)::timestamptz,sqlc.arg(after_id)::uuid)
ORDER BY e.created_at DESC,e.id DESC LIMIT sqlc.arg(page_limit);
-- name: SocialAssetAllowed :one
SELECT (NOT EXISTS(SELECT FROM social.post_media m WHERE m.asset_id=$1 AND NOT social.can_read(m.post_id,$2::uuid)))::boolean;

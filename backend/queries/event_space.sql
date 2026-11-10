-- name: SpaceRead :one
SELECT event_space.can_read($1::uuid,$2::uuid)::boolean;
-- name: SpaceWrite :one
SELECT event_space.can_write($1::uuid,$2::uuid)::boolean;
-- name: SpaceModerate :one
SELECT event_space.can_moderate($1::uuid,$2::uuid)::boolean;
-- name: SpaceSummary :one
SELECT jsonb_build_object('experience_id',e.id,'title',e.title,'description',CASE WHEN e.status='PUBLISHED' OR event_space.can_read(e.id,sqlc.arg(viewer)::uuid) THEN e.description ELSE '' END,
'cover_media_id',CASE WHEN e.status='PUBLISHED' THEN e.cover_media_id ELSE NULL END,
'starts_at',CASE WHEN e.status='PUBLISHED' OR event_space.can_read(e.id,sqlc.arg(viewer)) THEN e.starts_at ELSE NULL END,
'ends_at',CASE WHEN e.status='PUBLISHED' OR event_space.can_read(e.id,sqlc.arg(viewer)) THEN e.ends_at ELSE NULL END,
'visibility',e.visibility,'status',e.status,'phase',CASE WHEN e.status<>'PUBLISHED' THEN e.status WHEN e.ends_at<=now() THEN 'ENDED' WHEN e.starts_at<=now() THEN 'LIVE' ELSE 'UPCOMING' END,
'my_state',coalesce(m.state,'NONE'),'interested',coalesce(m.interested,false),
'role',CASE WHEN e.creator_user_id=sqlc.arg(viewer) THEN 'CREATOR' WHEN EXISTS(SELECT FROM event_space.moderators r WHERE r.experience_id=e.id AND r.user_id=sqlc.arg(viewer) AND r.active) AND event_space.can_read(e.id,sqlc.arg(viewer)) THEN 'MODERATOR' WHEN event_space.can_read(e.id,sqlc.arg(viewer)) THEN 'PARTICIPANT' ELSE 'VISITOR' END,
'paused',CASE WHEN e.creator_user_id=sqlc.arg(viewer) OR event_space.can_read(e.id,sqlc.arg(viewer)) THEN coalesce(s.paused,false) ELSE NULL END,'platform_suspended',CASE WHEN e.creator_user_id=sqlc.arg(viewer) THEN coalesce(s.platform_suspended,false) ELSE NULL END,
'participant_count',CASE WHEN event_space.can_read(e.id,sqlc.arg(viewer)) THEN (SELECT count(*) FROM participation.members p WHERE p.experience_id=e.id AND p.state='CONFIRMED' AND NOT p.blocked AND social.connected(p.user_id,sqlc.arg(viewer)) AND social.connected(p.user_id,e.creator_user_id)) ELSE NULL END,
'capabilities',jsonb_build_object('can_read',event_space.can_read(e.id,sqlc.arg(viewer)),'can_write',event_space.can_write(e.id,sqlc.arg(viewer)),'can_moderate',event_space.can_moderate(e.id,sqlc.arg(viewer)),'can_manage_roles',e.creator_user_id=sqlc.arg(viewer) AND event_space.can_moderate(e.id,sqlc.arg(viewer)),'can_manage_participation',e.creator_user_id=sqlc.arg(viewer) AND event_space.can_moderate(e.id,sqlc.arg(viewer))),
'as_of',now(),'valid_until',least(now()+interval '30 seconds',CASE WHEN e.status='PUBLISHED' AND e.ends_at>now() THEN e.ends_at ELSE now()+interval '30 seconds' END))::jsonb AS document
FROM experiences.experiences e LEFT JOIN participation.members m ON m.experience_id=e.id AND m.user_id=sqlc.arg(viewer)
LEFT JOIN event_space.settings s ON s.experience_id=e.id
WHERE e.id=sqlc.arg(experience_id) AND social.connected(e.creator_user_id,sqlc.arg(viewer)) AND e.moderation_status='VISIBLE'
AND (e.creator_user_id=sqlc.arg(viewer) OR event_space.can_read(e.id,sqlc.arg(viewer)) OR (e.visibility<>'PRIVATE' AND e.published_at IS NOT NULL AND participation.can_access(e.id,sqlc.arg(viewer))));
-- name: SpaceFeed :many
SELECT p.id,p.created_at,social.post_document(p.id,sqlc.arg(viewer)::uuid)::jsonb AS document FROM social.posts p
WHERE p.experience_id=sqlc.arg(experience_id) AND p.context='EVENT_SPACE' AND p.deleted_at IS NULL AND p.moderation_status='VISIBLE' AND NOT p.local_hidden
AND social.can_read(p.id,sqlc.arg(viewer)) AND p.created_at<=sqlc.arg(snapshot)::timestamptz AND (p.created_at,p.id)<(sqlc.arg(after_time)::timestamptz,sqlc.arg(after_id)::uuid)
ORDER BY p.created_at DESC,p.id DESC LIMIT sqlc.arg(page_limit);
-- name: SpaceGallery :many
SELECT a.id,p.created_at,jsonb_build_object('id',a.id,'post_id',p.id,'post',social.post_document(p.id,sqlc.arg(viewer)::uuid))::jsonb AS document
FROM social.posts p JOIN social.post_media m ON m.post_id=p.id JOIN media.flow_assets a ON a.id=m.asset_id AND a.status='READY'
WHERE p.experience_id=sqlc.arg(experience_id) AND p.context='EVENT_SPACE' AND p.deleted_at IS NULL AND p.moderation_status='VISIBLE' AND NOT p.local_hidden
AND social.can_read(p.id,sqlc.arg(viewer)) AND p.created_at<=sqlc.arg(snapshot)::timestamptz AND (p.created_at,a.id)<(sqlc.arg(after_time)::timestamptz,sqlc.arg(after_id)::uuid)
ORDER BY p.created_at DESC,a.id DESC LIMIT sqlc.arg(page_limit);
-- name: SpaceParticipants :many
WITH people AS (
 SELECT e.creator_user_id AS user_id,e.created_at,'CREATOR'::text AS role FROM experiences.experiences e WHERE e.id=sqlc.arg(experience_id)::uuid
 UNION ALL
 SELECT m.user_id,m.created_at,CASE WHEN coalesce(r.active,false) THEN 'MODERATOR' ELSE 'PARTICIPANT' END FROM participation.members m
 LEFT JOIN event_space.moderators r ON r.experience_id=m.experience_id AND r.user_id=m.user_id
 WHERE m.experience_id=sqlc.arg(experience_id) AND m.state='CONFIRMED' AND NOT m.blocked)
SELECT p.user_id AS id,p.created_at,(social.person(p.user_id)||jsonb_build_object('role',p.role))::jsonb AS document FROM people p
WHERE event_space.can_read(sqlc.arg(experience_id),sqlc.arg(viewer)::uuid) AND event_space.can_read(sqlc.arg(experience_id),p.user_id) AND social.connected(p.user_id,sqlc.arg(viewer))
AND p.created_at<=sqlc.arg(snapshot)::timestamptz AND (p.created_at,p.user_id)<(sqlc.arg(after_time)::timestamptz,sqlc.arg(after_id)::uuid)
ORDER BY p.created_at DESC,p.user_id DESC LIMIT sqlc.arg(page_limit);
-- name: SpaceReports :many
SELECT r.id,r.created_at,jsonb_build_object('id',r.id,'target_type',r.target_type,'target_id',r.target_id,'reason',r.reason,'created_at',r.created_at,'reviewed',v.report_id IS NOT NULL)::jsonb AS document
FROM social.reports r LEFT JOIN social.comments c ON r.target_type='COMMENT' AND c.id=r.target_id
LEFT JOIN social.posts p ON p.id=CASE WHEN r.target_type='POST' THEN r.target_id WHEN r.target_type='COMMENT' THEN c.post_id ELSE NULL END
LEFT JOIN chat.messages m ON r.target_type='CHAT_MESSAGE' AND m.id=r.target_id
LEFT JOIN event_space.report_reviews v ON v.report_id=r.id
WHERE (CASE WHEN r.target_type='CHAT_MESSAGE' THEN m.experience_id ELSE p.experience_id END)=sqlc.arg(experience_id)::uuid AND (p.context='EVENT_SPACE' OR m.id IS NOT NULL) AND event_space.can_moderate(sqlc.arg(experience_id),sqlc.arg(viewer)::uuid)
AND r.created_at<=sqlc.arg(snapshot)::timestamptz AND (r.created_at,r.id)<(sqlc.arg(after_time)::timestamptz,sqlc.arg(after_id)::uuid)
ORDER BY r.created_at DESC,r.id DESC LIMIT sqlc.arg(page_limit);
-- name: SpaceHidden :many
WITH hidden AS (
 SELECT p.id,p.created_at,'POST'::text AS target_type FROM social.posts p WHERE p.experience_id=sqlc.arg(experience_id)::uuid AND p.context='EVENT_SPACE' AND p.local_hidden AND p.deleted_at IS NULL
 UNION ALL
 SELECT c.id,c.created_at,'COMMENT'::text FROM social.comments c JOIN social.posts p ON p.id=c.post_id WHERE p.experience_id=sqlc.arg(experience_id) AND p.context='EVENT_SPACE' AND c.local_hidden AND c.deleted_at IS NULL)
SELECT h.id,h.created_at,jsonb_build_object('id',h.id,'target_id',h.id,'target_type',h.target_type,'created_at',h.created_at)::jsonb AS document FROM hidden h
WHERE event_space.can_moderate(sqlc.arg(experience_id),sqlc.arg(viewer)::uuid)
AND h.created_at<=sqlc.arg(snapshot)::timestamptz AND (h.created_at,h.id)<(sqlc.arg(after_time)::timestamptz,sqlc.arg(after_id)::uuid)
ORDER BY h.created_at DESC,h.id DESC LIMIT sqlc.arg(page_limit);
-- name: SpaceSetPostHidden :exec
UPDATE social.posts SET local_hidden=$2,version=version+1,updated_at=now() WHERE id=$1;
-- name: SpaceSetCommentHidden :exec
UPDATE social.comments SET local_hidden=$2 WHERE id=$1;
-- name: SpaceSetRestriction :exec
INSERT INTO event_space.restrictions(experience_id,user_id,restricted) VALUES($1,$2,$3) ON CONFLICT(experience_id,user_id) DO UPDATE SET restricted=excluded.restricted,updated_at=now();
-- name: SpaceSetModerator :exec
INSERT INTO event_space.moderators(experience_id,user_id,active) VALUES($1,$2,$3) ON CONFLICT(experience_id,user_id) DO UPDATE SET active=excluded.active,updated_at=now();
-- name: SpaceSetPaused :exec
INSERT INTO event_space.settings(experience_id,paused) VALUES($1,$2) ON CONFLICT(experience_id) DO UPDATE SET paused=excluded.paused,version=event_space.settings.version+1,updated_at=now();
-- name: SpaceSetPlatformSuspended :exec
INSERT INTO event_space.settings(experience_id,platform_suspended) VALUES($1,$2) ON CONFLICT(experience_id) DO UPDATE SET platform_suspended=excluded.platform_suspended,version=event_space.settings.version+1,updated_at=now();
-- name: SpaceReportTarget :one
SELECT r.id,coalesce(m.experience_id,p.experience_id)::uuid AS experience_id FROM social.reports r
LEFT JOIN social.comments c ON r.target_type='COMMENT' AND c.id=r.target_id
LEFT JOIN social.posts p ON p.id=CASE WHEN r.target_type='POST' THEN r.target_id WHEN r.target_type='COMMENT' THEN c.post_id ELSE NULL END
LEFT JOIN chat.messages m ON r.target_type='CHAT_MESSAGE' AND m.id=r.target_id
WHERE r.id=$1 AND (p.context='EVENT_SPACE' OR m.id IS NOT NULL);
-- name: SpaceReviewReport :exec
INSERT INTO event_space.report_reviews(report_id,experience_id,reviewed_by) VALUES($1,$2,$3) ON CONFLICT(report_id) DO UPDATE SET reviewed_by=excluded.reviewed_by,reviewed_at=now();
-- name: SocialPostScope :one
SELECT context,experience_id,author_user_id FROM social.posts WHERE id=$1;
-- name: SpaceMember :one
SELECT m.state,m.blocked,coalesce(r.active,false)::boolean AS moderator,coalesce(x.restricted,false)::boolean AS restricted FROM participation.members m LEFT JOIN event_space.moderators r ON r.experience_id=m.experience_id AND r.user_id=m.user_id LEFT JOIN event_space.restrictions x ON x.experience_id=m.experience_id AND x.user_id=m.user_id WHERE m.experience_id=$1 AND m.user_id=$2;
-- name: SocialCommentPost :one
SELECT post_id FROM social.comments WHERE id=$1;

-- name: SocialInteractionVisible :one
SELECT social.interaction_visible($1::uuid,$2::uuid,$3::uuid)::boolean;

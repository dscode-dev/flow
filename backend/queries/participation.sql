-- name: CanAccessParticipationExperience :one
SELECT participation.can_access($1::uuid,$2::uuid)::boolean;

-- name: ParticipationContext :one
SELECT d.document::jsonb AS document, (CASE WHEN d.visibility='PRIVATE' THEN 'INVITE' ELSE COALESCE(s.mode,'FREE') END)::text AS mode,COALESCE(s.version,1)::bigint AS settings_version,
 (SELECT count(*) FROM participation.members m WHERE m.experience_id=d.id AND m.state='CONFIRMED')::bigint AS confirmed_count,
 (SELECT status FROM identity.users WHERE id=d.creator_user_id)::text AS creator_status,
 participation.can_access(d.id,sqlc.arg(viewer)::uuid)::boolean AS accessible,clock_timestamp()::timestamptz AS as_of
FROM experiences.documents d LEFT JOIN participation.settings s ON s.experience_id=d.id WHERE d.id=sqlc.arg(experience_id);

-- name: GetParticipationMember :one
SELECT * FROM participation.members WHERE experience_id=$1 AND user_id=$2;

-- name: SaveParticipationMember :one
INSERT INTO participation.members(id,experience_id,user_id,interested,state,blocked)
VALUES($1,$2,$3,$4,$5,$6)
ON CONFLICT(experience_id,user_id) DO UPDATE SET interested=excluded.interested,state=excluded.state,blocked=excluded.blocked,
 version=participation.members.version+1,updated_at=clock_timestamp() RETURNING *;

-- name: SaveParticipationSettings :exec
INSERT INTO participation.settings(experience_id,mode,version) VALUES($1,$2,2)
ON CONFLICT(experience_id) DO UPDATE SET mode=excluded.mode,version=participation.settings.version+1,updated_at=clock_timestamp();

-- name: UpdateExperienceCapacity :exec
UPDATE experiences.experiences SET capacity=$2,version=version+1,updated_at=clock_timestamp() WHERE id=$1;

-- name: FindParticipationInvitee :one
SELECT u.id FROM identity.users u JOIN identity.profiles p ON p.user_id=u.id
WHERE u.status='active' AND u.onboarding_completed_at IS NOT NULL
 AND ((sqlc.narg(user_id)::uuid IS NOT NULL AND u.id=sqlc.narg(user_id)) OR (sqlc.arg(handle)::text<>'' AND p.handle=sqlc.arg(handle)));

-- name: ParticipationTargetActive :one
SELECT EXISTS(SELECT FROM identity.users WHERE id=$1 AND status='active' AND onboarding_completed_at IS NOT NULL);

-- name: ParticipationPublicPerson :one
SELECT CASE WHEN u.status='active' THEN COALESCE(p.display_name,'') ELSE 'Conta indisponível' END::text AS display_name,
 COALESCE(CASE WHEN u.status='active' THEN p.handle ELSE NULL END,'')::text AS handle
FROM identity.users u LEFT JOIN identity.profiles p ON p.user_id=u.id WHERE u.id=$1;

-- name: GetParticipationInvitation :one
SELECT * FROM participation.invitations WHERE experience_id=$1 AND invitee_user_id=$2;

-- name: FindParticipationInvitation :one
SELECT * FROM participation.invitations WHERE id=$1;

-- name: SaveParticipationInvitation :one
INSERT INTO participation.invitations(id,experience_id,invitee_user_id,sender_user_id,state,expires_at)
VALUES($1,$2,$3,$4,$5,$6)
ON CONFLICT(experience_id,invitee_user_id) DO UPDATE SET id=excluded.id,sender_user_id=excluded.sender_user_id,state=excluded.state,expires_at=excluded.expires_at,
 version=participation.invitations.version+1,updated_at=clock_timestamp() RETURNING *;

-- name: UpdateParticipationInvitation :one
UPDATE participation.invitations SET state=$2,version=version+1,updated_at=clock_timestamp() WHERE id=$1 RETURNING *;

-- name: SaveCheckinCredential :exec
INSERT INTO participation.checkin_credentials(experience_id,user_id,id,code_hash,expires_at,session_id) VALUES($1,$2,$3,$4,$5,$6)
ON CONFLICT(experience_id,user_id) DO UPDATE SET id=excluded.id,code_hash=excluded.code_hash,expires_at=excluded.expires_at,session_id=excluded.session_id,used_at=NULL;

-- name: ParticipationCredentialSessionActive :one
SELECT EXISTS(SELECT FROM identity.sessions WHERE id=$1 AND revoked_at IS NULL AND expires_at>now());

-- name: GetCheckinCredential :one
SELECT * FROM participation.checkin_credentials WHERE experience_id=$1 AND code_hash=$2 FOR UPDATE;

-- name: ConsumeCheckinCredential :exec
UPDATE participation.checkin_credentials SET used_at=clock_timestamp() WHERE id=$1;

-- name: RevokeCheckinCredential :exec
UPDATE participation.checkin_credentials SET used_at=COALESCE(used_at,clock_timestamp()) WHERE experience_id=$1 AND user_id=$2;

-- name: GetParticipationCheckin :one
SELECT * FROM participation.checkins WHERE experience_id=$1 AND user_id=$2;

-- name: SaveParticipationCheckin :one
INSERT INTO participation.checkins(id,experience_id,user_id,checked_at,checked_by) VALUES($1,$2,$3,clock_timestamp(),$4)
ON CONFLICT(experience_id,user_id) DO UPDATE SET checked_at=clock_timestamp(),checked_by=excluded.checked_by,revoked_at=NULL,revoked_by=NULL,version=participation.checkins.version+1 RETURNING *;

-- name: RevokeParticipationCheckin :one
UPDATE participation.checkins SET revoked_at=clock_timestamp(),revoked_by=$3,version=version+1 WHERE experience_id=$1 AND user_id=$2 AND revoked_at IS NULL RETURNING *;

-- name: InsertParticipationAudit :exec
INSERT INTO participation.audit(id,experience_id,actor_user_id,subject_user_id,action,resource_version,request_id,details) VALUES($1,$2,$3,$4,$5,$6,$7,$8);

-- name: ParticipationIdempotency :one
SELECT request_hash,response FROM participation.idempotency WHERE actor_user_id=$1 AND key=$2 AND expires_at>now();

-- name: SaveParticipationIdempotency :exec
INSERT INTO participation.idempotency(actor_user_id,key,request_hash,response) VALUES($1,$2,$3,$4)
ON CONFLICT(actor_user_id,key) DO UPDATE SET request_hash=excluded.request_hash,response=excluded.response,created_at=now(),expires_at=now()+interval '24 hours';

-- name: ParticipationRate :one
INSERT INTO participation.rate_limits(user_id,window_start,count) VALUES($1,date_trunc('minute',now()),1)
ON CONFLICT(user_id,window_start) DO UPDATE SET count=participation.rate_limits.count+1 RETURNING count;

-- name: ListParticipationMembers :many
SELECT jsonb_build_object('user_id',m.user_id,'display_name',CASE WHEN u.status='active' THEN p.display_name ELSE 'Conta indisponível' END,
 'handle',CASE WHEN u.status='active' THEN p.handle ELSE NULL END,'state',m.state,'interested',m.interested,'blocked',m.blocked,'version',m.version,'updated_at',m.updated_at,
 'checked_in',c.id IS NOT NULL AND c.revoked_at IS NULL,'checked_at',CASE WHEN c.revoked_at IS NULL THEN c.checked_at ELSE NULL END)::jsonb AS document
FROM participation.members m JOIN identity.users u ON u.id=m.user_id LEFT JOIN identity.profiles p ON p.user_id=m.user_id
LEFT JOIN participation.checkins c ON c.experience_id=m.experience_id AND c.user_id=m.user_id
WHERE m.experience_id=sqlc.arg(experience_id) AND (sqlc.arg(state_filter)::text='' OR m.state=sqlc.arg(state_filter))
 AND m.user_id>sqlc.arg(after_id)::uuid ORDER BY m.user_id LIMIT sqlc.arg(page_limit);

-- name: ListParticipationInvitations :many
SELECT jsonb_build_object('id',i.id,'experience_id',i.experience_id,'invitee_user_id',i.invitee_user_id,'state',i.state,
 'expires_at',i.expires_at,'version',i.version,'display_name',CASE WHEN u.status='active' THEN p.display_name ELSE 'Conta indisponível' END,
 'handle',CASE WHEN u.status='active' THEN p.handle ELSE NULL END,'expired',i.expires_at<=now())::jsonb AS document
FROM participation.invitations i JOIN identity.users u ON u.id=i.invitee_user_id LEFT JOIN identity.profiles p ON p.user_id=i.invitee_user_id
WHERE i.experience_id=sqlc.arg(experience_id) AND i.id>sqlc.arg(after_id)::uuid ORDER BY i.id LIMIT sqlc.arg(page_limit);

-- name: ListParticipationAgenda :many
WITH mine AS (
 SELECT mine_member.experience_id FROM participation.members mine_member WHERE mine_member.user_id=sqlc.arg(viewer)
 UNION SELECT mine_invite.experience_id FROM participation.invitations mine_invite WHERE mine_invite.invitee_user_id=sqlc.arg(viewer)
), entries AS (
 SELECT e.*,COALESCE(m.state,'NONE')::text AS member_state,COALESCE(m.interested,false) AS interested,COALESCE(m.blocked,false) AS blocked,
  m.updated_at AS member_updated_at,i.id AS invitation_id,i.state AS invitation_state,i.expires_at AS invitation_expires_at,
  COALESCE(c.revoked_at IS NULL AND c.id IS NOT NULL,false) AS checked_in,c.checked_at,
  participation.can_access(e.id,sqlc.arg(viewer))::boolean AS accessible,
  COALESCE(e.starts_at,m.updated_at,i.updated_at) AS actual_time,
  COALESCE(m.updated_at,i.updated_at) AS relation_time
 FROM mine JOIN experiences.experiences e ON e.id=mine.experience_id
 LEFT JOIN participation.members m ON m.experience_id=e.id AND m.user_id=sqlc.arg(viewer)
 LEFT JOIN participation.invitations i ON i.experience_id=e.id AND i.invitee_user_id=sqlc.arg(viewer)
 LEFT JOIN participation.checkins c ON c.experience_id=e.id AND c.user_id=sqlc.arg(viewer)
), selected AS (
 SELECT *,CASE WHEN accessible THEN actual_time ELSE relation_time END AS sort_time FROM entries
 WHERE (sqlc.arg(section)::text='upcoming' AND member_state='CONFIRMED' AND status='PUBLISHED' AND ends_at>now() AND accessible)
 OR (sqlc.arg(section)='interests' AND interested AND status='PUBLISHED' AND ends_at>now() AND accessible)
 OR (sqlc.arg(section)='pending' AND member_state='PENDING' AND status='PUBLISHED' AND ends_at>now() AND accessible)
 OR (sqlc.arg(section)='invitations' AND invitation_state='PENDING' AND invitation_expires_at>now() AND status='PUBLISHED' AND ends_at>now() AND accessible)
 OR (sqlc.arg(section)='history' AND (member_state IN ('DECLINED','CANCELLED','REMOVED') OR status<>'PUBLISHED' OR ends_at<=now() OR NOT accessible OR invitation_state IN ('DECLINED','REVOKED') OR invitation_expires_at<=now()))
)
SELECT jsonb_build_object('experience_id',id,'title',CASE WHEN accessible THEN title ELSE 'Experiência indisponível' END,
 'starts_at',CASE WHEN accessible THEN starts_at ELSE NULL END,'ends_at',CASE WHEN accessible THEN ends_at ELSE NULL END,
 'timezone',CASE WHEN accessible THEN timezone ELSE NULL END,'venue_name',CASE WHEN accessible AND status='PUBLISHED' THEN venue_name ELSE '' END,
 'experience_status',CASE WHEN accessible THEN status ELSE 'UNAVAILABLE' END,'accessible',accessible,'state',member_state,'interested',interested,
 'effective_state',CASE WHEN NOT accessible THEN 'UNAVAILABLE' WHEN status<>'PUBLISHED' THEN 'EXPERIENCE_'||status WHEN ends_at<=now() THEN 'ENDED' ELSE member_state END,
 'invitation_id',invitation_id,'invitation_state',invitation_state,'invitation_expires_at',invitation_expires_at,
 'checked_in',checked_in AND accessible AND status='PUBLISHED' AND member_state='CONFIRMED',
 'external_ticket',accessible AND external_ticket_url IS NOT NULL,'sort_time',sort_time)::jsonb AS document
FROM selected WHERE (sort_time,id)>(sqlc.arg(after_time)::timestamptz,sqlc.arg(after_id)::uuid)
ORDER BY sort_time,id LIMIT sqlc.arg(page_limit);

-- name: CleanupParticipationTechnical :exec
DELETE FROM participation.idempotency WHERE (actor_user_id,key) IN (SELECT actor_user_id,key FROM participation.idempotency WHERE expires_at<=now() ORDER BY expires_at LIMIT 500);
-- name: CleanupParticipationCredentials :exec
DELETE FROM participation.checkin_credentials WHERE id IN (SELECT id FROM participation.checkin_credentials WHERE expires_at<now()-interval '1 day' ORDER BY expires_at LIMIT 500);
-- name: CleanupParticipationRates :exec
DELETE FROM participation.rate_limits WHERE (user_id,window_start) IN (SELECT user_id,window_start FROM participation.rate_limits WHERE window_start<now()-interval '2 days' ORDER BY window_start LIMIT 500);
-- name: CleanupParticipationAudit :exec
DELETE FROM participation.audit WHERE id IN (SELECT id FROM participation.audit WHERE created_at<now()-interval '180 days' ORDER BY created_at,id LIMIT 500);

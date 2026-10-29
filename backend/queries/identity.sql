-- name: IdentityAdvisoryLock :exec
SELECT pg_advisory_xact_lock(hashtextextended($1::text,0));

-- name: CreateIdentityUser :exec
INSERT INTO identity.users(id) VALUES ($1);

-- name: CreateIdentityProfile :exec
INSERT INTO identity.profiles(user_id) VALUES ($1);

-- name: LockIdentityUser :one
SELECT id::text,status,onboarding_completed_at FROM identity.users WHERE id=$1 FOR UPDATE;

-- name: FindProviderIdentity :one
SELECT id::text,user_id::text,revoked_at FROM identity.auth_identities WHERE provider=$1 AND provider_subject=$2;

-- name: InsertProviderIdentity :exec
INSERT INTO identity.auth_identities(id,user_id,provider,provider_subject) VALUES ($1,$2,$3,$4);

-- name: RestoreProviderIdentity :exec
UPDATE identity.auth_identities SET revoked_at=NULL,verified_at=now(),updated_at=now() WHERE id=$1;

-- name: TouchAuthenticatedUser :exec
UPDATE identity.users SET last_authenticated_at=now(),updated_at=now() WHERE id=$1;

-- name: InsertIdentityDevice :exec
INSERT INTO identity.devices(id,user_id,platform,app_version,label) VALUES ($1,$2,$3,$4,$5);

-- name: CountActiveSessions :one
SELECT count(*) FROM identity.sessions WHERE user_id=$1 AND revoked_at IS NULL AND expires_at>now();

-- name: InsertIdentitySession :exec
INSERT INTO identity.sessions(id,user_id,device_id,authenticated_provider,expires_at) VALUES ($1,$2,$3,$4,$5);

-- name: InsertRefreshCredential :exec
INSERT INTO identity.refresh_credentials(id,session_id,credential_hash,expires_at) VALUES($1,$2,$3,$4);

-- name: InsertAccessCredential :exec
INSERT INTO identity.access_credentials(credential_hash,session_id,expires_at) VALUES($1,$2,$3);

-- name: FindAccessSession :one
SELECT s.id::text,s.user_id::text,s.reauthenticated_at,s.expires_at,u.status
FROM identity.access_credentials a JOIN identity.sessions s ON s.id=a.session_id JOIN identity.users u ON u.id=s.user_id
WHERE a.credential_hash=$1 AND a.expires_at>now() AND s.expires_at>now() AND s.revoked_at IS NULL;

-- name: FindRefreshOwner :one
SELECT r.session_id::text,s.user_id::text FROM identity.refresh_credentials r JOIN identity.sessions s ON s.id=r.session_id WHERE r.id=$1;

-- name: LockIdentitySession :one
SELECT id::text,user_id::text,expires_at,reauthenticated_at,revoked_at FROM identity.sessions WHERE id=$1 FOR UPDATE;

-- name: LockRefreshCredential :one
SELECT credential_hash,expires_at,used_at FROM identity.refresh_credentials WHERE id=$1 AND session_id=$2 FOR UPDATE;

-- name: ConsumeRefreshCredential :exec
UPDATE identity.refresh_credentials SET used_at=now() WHERE id=$1;

-- name: TouchIdentitySession :exec
WITH touched AS (UPDATE identity.sessions AS s SET last_used_at=now() WHERE s.id=$1 RETURNING s.device_id)
UPDATE identity.devices AS d SET last_seen_at=now() WHERE d.id IN (SELECT touched.device_id FROM touched);

-- name: ReauthenticateIdentitySession :exec
UPDATE identity.sessions SET reauthenticated_at=now(),authenticated_provider=$2,last_used_at=now() WHERE id=$1;

-- name: RevokeIdentitySession :execrows
UPDATE identity.sessions SET revoked_at=now(),revocation_reason=$3 WHERE id=$1 AND user_id=$2 AND revoked_at IS NULL;

-- name: ActiveUserSessionIDs :many
SELECT id::text FROM identity.sessions WHERE user_id=$1 AND revoked_at IS NULL ORDER BY id;

-- name: ListIdentitySessions :many
SELECT s.id::text,s.created_at,s.expires_at,s.last_used_at,d.platform,d.app_version,d.label
FROM identity.sessions s JOIN identity.devices d ON d.id=s.device_id
WHERE s.user_id=$1 AND s.revoked_at IS NULL AND s.expires_at>now()
ORDER BY s.created_at DESC,s.id LIMIT 20;

-- name: IdentityMe :one
SELECT u.id::text,u.status,u.created_at,u.onboarding_completed_at,p.display_name,p.handle,p.avatar_ref
FROM identity.users u JOIN identity.profiles p ON p.user_id=u.id WHERE u.id=$1;

-- name: CompleteIdentityOnboarding :exec
UPDATE identity.profiles SET display_name=$2,handle=$3,updated_at=now() WHERE user_id=$1;

-- name: MarkIdentityOnboarding :exec
UPDATE identity.users SET onboarding_completed_at=COALESCE(onboarding_completed_at,now()),updated_at=now() WHERE id=$1;

-- name: IsReservedHandle :one
SELECT EXISTS(SELECT FROM identity.reserved_handles WHERE handle=$1) AS reserved;

-- name: ListUserIdentities :many
SELECT id::text,provider,verified_at FROM identity.auth_identities WHERE user_id=$1 AND revoked_at IS NULL ORDER BY created_at,id;

-- name: RevokeProviderIdentity :execrows
UPDATE identity.auth_identities SET revoked_at=now(),updated_at=now() WHERE id=$1 AND user_id=$2 AND revoked_at IS NULL;

-- name: SupersedePhoneChallenges :exec
UPDATE identity.challenges SET status='superseded' WHERE subject_ref=$1 AND provider='PHONE' AND status IN ('sending','pending');

-- name: LastPhoneChallengeAt :one
SELECT max(created_at)::timestamptz AS last_created_at FROM identity.challenges WHERE subject_ref=$1 AND provider='PHONE';

-- name: InsertIdentityChallenge :exec
INSERT INTO identity.challenges(id,provider,purpose,session_id,subject_ref,nonce_hash,status,expires_at,origin_ref)
VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9);

-- name: SetChallengeDelivery :exec
UPDATE identity.challenges SET provider_reference=$2,status=$3 WHERE id=$1 AND status='sending';

-- name: LockIdentityChallenge :one
SELECT id::text,provider,purpose,session_id,subject_ref,nonce_hash,provider_reference,status,attempts,expires_at
FROM identity.challenges WHERE id=$1 FOR UPDATE;

-- name: AttemptIdentityChallenge :exec
UPDATE identity.challenges SET attempts=attempts+1,status=CASE WHEN attempts+1 >= $2 THEN 'exhausted' ELSE status END WHERE id=$1;

-- name: ConsumeIdentityChallenge :exec
UPDATE identity.challenges SET status='consumed',consumed_at=now() WHERE id=$1;

-- name: IncrementIdentityBucket :one
INSERT INTO identity.rate_limits(bucket_key,count,expires_at) VALUES($1,1,$2)
ON CONFLICT(bucket_key) DO UPDATE SET count=identity.rate_limits.count+1
WHERE identity.rate_limits.count < $3 RETURNING count;

-- name: InsertIdentityAudit :exec
INSERT INTO identity.audit_events(id,user_id,session_id,action,outcome,reason,request_id) VALUES($1,$2,$3,$4,$5,$6,$7);

-- name: RegisterAppleNotification :execrows
INSERT INTO identity.provider_notifications(digest) VALUES($1) ON CONFLICT DO NOTHING;

-- name: PruneIdentityAccess :execrows
DELETE FROM identity.access_credentials WHERE expires_at < now()-interval '1 day';

-- name: PruneIdentityChallenges :execrows
DELETE FROM identity.challenges WHERE expires_at < now()-interval '1 day';

-- name: PruneIdentityRateLimits :execrows
DELETE FROM identity.rate_limits WHERE expires_at < now()-interval '1 day';

-- name: PruneIdentityNotifications :execrows
DELETE FROM identity.provider_notifications WHERE received_at < now()-interval '8 days';

-- name: PruneIdentitySessionAccess :execrows
DELETE FROM identity.access_credentials a USING identity.sessions s
WHERE a.session_id=s.id AND s.expires_at < now()-interval '30 days';

-- name: PruneIdentityRefreshHistory :execrows
DELETE FROM identity.refresh_credentials r USING identity.sessions s
WHERE r.session_id=s.id AND s.expires_at < now()-interval '30 days';

-- name: PruneIdentityChallengeSessions :execrows
DELETE FROM identity.challenges c USING identity.sessions s
WHERE c.session_id=s.id AND s.expires_at < now()-interval '30 days';

-- name: PruneIdentitySessions :execrows
DELETE FROM identity.sessions WHERE expires_at < now()-interval '30 days';

-- name: PruneIdentityDevices :execrows
DELETE FROM identity.devices d WHERE d.last_seen_at < now()-interval '30 days'
AND NOT EXISTS(SELECT FROM identity.sessions s WHERE s.device_id=d.id);

-- name: PruneIdentityAudit :execrows
DELETE FROM identity.audit_events WHERE created_at < now()-interval '180 days';

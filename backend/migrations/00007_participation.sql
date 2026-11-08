-- +goose Up
CREATE SCHEMA participation;
CREATE TABLE participation.settings (
 experience_id uuid PRIMARY KEY REFERENCES experiences.experiences(id),
 mode text NOT NULL DEFAULT 'FREE' CHECK(mode IN ('FREE','APPROVAL','INVITE')),
 version bigint NOT NULL DEFAULT 1 CHECK(version>0), updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE participation.members (
 id uuid PRIMARY KEY,
 experience_id uuid NOT NULL REFERENCES experiences.experiences(id),
 user_id uuid NOT NULL REFERENCES identity.users(id),
 interested boolean NOT NULL DEFAULT false,
 state text NOT NULL DEFAULT 'NONE' CHECK(state IN ('NONE','PENDING','CONFIRMED','DECLINED','CANCELLED','REMOVED')),
 blocked boolean NOT NULL DEFAULT false,
 version bigint NOT NULL DEFAULT 1 CHECK(version>0),
 created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE(experience_id,user_id), CHECK(NOT blocked OR state='REMOVED')
);
CREATE INDEX participation_members_user ON participation.members(user_id,experience_id);
CREATE INDEX participation_members_roster ON participation.members(experience_id,state,user_id);
CREATE TABLE participation.invitations (
 id uuid PRIMARY KEY, experience_id uuid NOT NULL REFERENCES experiences.experiences(id),
 invitee_user_id uuid NOT NULL REFERENCES identity.users(id), sender_user_id uuid NOT NULL REFERENCES identity.users(id),
 state text NOT NULL CHECK(state IN ('PENDING','ACCEPTED','DECLINED','REVOKED')),
 expires_at timestamptz NOT NULL, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
 version bigint NOT NULL DEFAULT 1 CHECK(version>0),
 UNIQUE(experience_id,invitee_user_id), CHECK(invitee_user_id<>sender_user_id)
);
CREATE INDEX participation_invitation_recipient ON participation.invitations(invitee_user_id,state,experience_id);
CREATE TABLE participation.checkin_credentials (
 experience_id uuid NOT NULL, user_id uuid NOT NULL, id uuid NOT NULL UNIQUE,
 session_id uuid NOT NULL REFERENCES identity.sessions(id),
 code_hash bytea NOT NULL UNIQUE CHECK(octet_length(code_hash)=32),
 expires_at timestamptz NOT NULL, used_at timestamptz,
 PRIMARY KEY(experience_id,user_id),
 FOREIGN KEY(experience_id,user_id) REFERENCES participation.members(experience_id,user_id)
);
CREATE TABLE participation.checkins (
 id uuid PRIMARY KEY, experience_id uuid NOT NULL, user_id uuid NOT NULL,
 checked_at timestamptz NOT NULL, checked_by uuid NOT NULL REFERENCES identity.users(id),
 revoked_at timestamptz, revoked_by uuid REFERENCES identity.users(id),
 version bigint NOT NULL DEFAULT 1 CHECK(version>0),
 UNIQUE(experience_id,user_id),
 FOREIGN KEY(experience_id,user_id) REFERENCES participation.members(experience_id,user_id),
 CHECK((revoked_at IS NULL)=(revoked_by IS NULL))
);
CREATE TABLE participation.audit (
 id uuid PRIMARY KEY, experience_id uuid NOT NULL, actor_user_id uuid NOT NULL,
 subject_user_id uuid NOT NULL, action text NOT NULL, resource_version bigint NOT NULL,
 request_id text NOT NULL, details jsonb NOT NULL DEFAULT '{}', created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX participation_audit_resource ON participation.audit(experience_id,created_at,id);
CREATE INDEX participation_audit_retention ON participation.audit(created_at,id);
CREATE TABLE participation.idempotency (
 actor_user_id uuid NOT NULL, key uuid NOT NULL, request_hash bytea NOT NULL CHECK(octet_length(request_hash)=32),
 response jsonb NOT NULL, created_at timestamptz NOT NULL DEFAULT now(), expires_at timestamptz NOT NULL DEFAULT now()+interval '24 hours',
 PRIMARY KEY(actor_user_id,key)
);
CREATE INDEX participation_idempotency_expiry ON participation.idempotency(expires_at);
CREATE TABLE participation.rate_limits (
 user_id uuid NOT NULL, window_start timestamptz NOT NULL, count integer NOT NULL,
 PRIMARY KEY(user_id,window_start)
);

-- Confirmations and capacity edits have the same PostgreSQL serialization point.
-- This protects even a writer that omits the service's explicit parent lock.
-- +goose StatementBegin
CREATE FUNCTION participation.enforce_seats() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE maximum integer; occupied bigint;
BEGIN
 IF NEW.state='CONFIRMED' THEN
  IF TG_OP='UPDATE' THEN
   IF OLD.state='CONFIRMED' THEN RETURN NEW; END IF;
  END IF;
  SELECT capacity INTO maximum FROM experiences.experiences WHERE id=NEW.experience_id FOR UPDATE;
  SELECT count(*) INTO occupied FROM participation.members WHERE experience_id=NEW.experience_id AND state='CONFIRMED' AND id<>NEW.id;
  IF maximum IS NOT NULL AND occupied>=maximum THEN
   RAISE EXCEPTION 'capacity exceeded' USING ERRCODE='23514', CONSTRAINT='participation_capacity';
  END IF;
 END IF;
 RETURN NEW;
END $$;
-- +goose StatementEnd
CREATE TRIGGER participation_seats BEFORE INSERT OR UPDATE OF state ON participation.members FOR EACH ROW EXECUTE FUNCTION participation.enforce_seats();
-- +goose StatementBegin
CREATE FUNCTION participation.enforce_capacity() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF NEW.capacity IS NOT NULL AND NEW.capacity IS DISTINCT FROM OLD.capacity AND
  NEW.capacity<(SELECT count(*) FROM participation.members WHERE experience_id=NEW.id AND state='CONFIRMED') THEN
  RAISE EXCEPTION 'capacity below confirmations' USING ERRCODE='23514', CONSTRAINT='participation_capacity';
 END IF;
 RETURN NEW;
END $$;
-- +goose StatementEnd
CREATE TRIGGER participation_capacity BEFORE UPDATE OF capacity ON experiences.experiences FOR EACH ROW EXECUTE FUNCTION participation.enforce_capacity();

-- One authorization predicate reused by details, cover, agenda and participation.
-- A UUID/link alone never grants PRIVATE access. Blocks also override old invites.
-- +goose StatementBegin
CREATE FUNCTION participation.can_access(eid uuid, viewer uuid) RETURNS boolean LANGUAGE sql STABLE AS $$
 SELECT EXISTS(SELECT FROM experiences.experiences e JOIN identity.users creator ON creator.id=e.creator_user_id AND creator.status='active'
 WHERE e.id=eid AND (e.creator_user_id=viewer OR
  (e.published_at IS NOT NULL AND e.moderation_status='VISIBLE'
   AND NOT EXISTS(SELECT FROM participation.members b WHERE b.experience_id=e.id AND b.user_id=viewer AND b.blocked)
   AND (e.visibility<>'PRIVATE'
    OR EXISTS(SELECT FROM participation.members m WHERE m.experience_id=e.id AND m.user_id=viewer AND m.state='CONFIRMED')
    OR EXISTS(SELECT FROM participation.invitations i WHERE i.experience_id=e.id AND i.invitee_user_id=viewer AND i.state='PENDING' AND i.expires_at>now())))))
$$;
-- +goose StatementEnd

-- +goose Down
DROP TRIGGER participation_capacity ON experiences.experiences;
DROP SCHEMA participation CASCADE;

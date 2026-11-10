-- +goose Up
CREATE SCHEMA chat;
CREATE TABLE chat.rooms(experience_id uuid PRIMARY KEY REFERENCES experiences.experiences(id),sequence bigint NOT NULL DEFAULT 0 CHECK(sequence>=0));
CREATE TABLE chat.messages(id uuid PRIMARY KEY,experience_id uuid NOT NULL REFERENCES experiences.experiences(id),author_user_id uuid NOT NULL REFERENCES identity.users(id),client_message_id uuid NOT NULL,request_hash bytea NOT NULL CHECK(octet_length(request_hash)=32),body text CHECK(body IS NULL OR char_length(body) BETWEEN 1 AND 3000),sequence bigint NOT NULL CHECK(sequence>0),created_at timestamptz NOT NULL DEFAULT now(),deleted_at timestamptz,moderation_status text NOT NULL DEFAULT 'VISIBLE' CHECK(moderation_status IN ('VISIBLE','WITHHELD')),UNIQUE(experience_id,author_user_id,client_message_id),UNIQUE(experience_id,sequence));
CREATE INDEX chat_message_history ON chat.messages(experience_id,sequence DESC);
CREATE INDEX chat_message_expiry ON chat.messages(created_at) WHERE body IS NOT NULL;
CREATE TABLE chat.changes(experience_id uuid NOT NULL REFERENCES experiences.experiences(id),sequence bigint NOT NULL,message_id uuid NOT NULL REFERENCES chat.messages(id),created_at timestamptz NOT NULL DEFAULT now(),PRIMARY KEY(experience_id,sequence));
CREATE TABLE chat.connections(id uuid PRIMARY KEY,user_id uuid NOT NULL REFERENCES identity.users(id),session_id uuid NOT NULL REFERENCES identity.sessions(id),experience_id uuid NOT NULL REFERENCES experiences.experiences(id),expires_at timestamptz NOT NULL);
CREATE INDEX chat_connection_expiry ON chat.connections(expires_at);
CREATE TABLE chat.policy_clock(id boolean PRIMARY KEY DEFAULT true CHECK(id),version bigint NOT NULL DEFAULT 1);
INSERT INTO chat.policy_clock(id) VALUES(true);
-- A conservative cross-instance invalidation counter, no PII or behavioral log.
-- +goose StatementBegin
CREATE FUNCTION chat.policy_changed() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN UPDATE chat.policy_clock SET version=version+1 WHERE id;RETURN NULL;END $$;
-- +goose StatementEnd
CREATE TRIGGER chat_policy_members AFTER UPDATE OF state,blocked ON participation.members FOR EACH STATEMENT EXECUTE FUNCTION chat.policy_changed();
CREATE TRIGGER chat_policy_users AFTER UPDATE OF status,onboarding_completed_at ON identity.users FOR EACH STATEMENT EXECUTE FUNCTION chat.policy_changed();
CREATE TRIGGER chat_policy_sessions AFTER UPDATE OF revoked_at ON identity.sessions FOR EACH STATEMENT EXECUTE FUNCTION chat.policy_changed();
CREATE TRIGGER chat_policy_experiences AFTER UPDATE OF status,ends_at,moderation_status ON experiences.experiences FOR EACH STATEMENT EXECUTE FUNCTION chat.policy_changed();
CREATE TRIGGER chat_policy_blocks AFTER INSERT OR UPDATE OR DELETE ON social.blocks FOR EACH STATEMENT EXECUTE FUNCTION chat.policy_changed();
CREATE TRIGGER chat_policy_restrictions AFTER INSERT OR UPDATE OR DELETE ON social.restrictions FOR EACH STATEMENT EXECUTE FUNCTION chat.policy_changed();
CREATE TRIGGER chat_policy_spaces AFTER INSERT OR UPDATE OR DELETE ON event_space.settings FOR EACH STATEMENT EXECUTE FUNCTION chat.policy_changed();
CREATE TRIGGER chat_policy_local AFTER INSERT OR UPDATE OR DELETE ON event_space.restrictions FOR EACH STATEMENT EXECUTE FUNCTION chat.policy_changed();
CREATE TRIGGER chat_policy_roles AFTER INSERT OR UPDATE OR DELETE ON event_space.moderators FOR EACH STATEMENT EXECUTE FUNCTION chat.policy_changed();
CREATE TRIGGER chat_policy_publish AFTER INSERT OR UPDATE OR DELETE ON experiences.publishing_restrictions FOR EACH STATEMENT EXECUTE FUNCTION chat.policy_changed();
ALTER TABLE social.reports DROP CONSTRAINT reports_target_type_check;
ALTER TABLE social.reports ADD CONSTRAINT reports_target_type_check CHECK(target_type IN ('USER','POST','COMMENT','CHAT_MESSAGE'));
-- +goose StatementBegin
CREATE FUNCTION chat.document(mid uuid,viewer uuid) RETURNS jsonb LANGUAGE sql STABLE AS $$
SELECT jsonb_build_object('id',m.id,'experience_id',m.experience_id,'client_message_id',CASE WHEN m.author_user_id=viewer THEN m.client_message_id ELSE NULL END,'sequence',m.sequence::text,'created_at',m.created_at,'removed',NOT v.allowed,'body',CASE WHEN v.allowed THEN m.body ELSE NULL END,'author',CASE WHEN v.allowed THEN social.person(m.author_user_id) ELSE NULL END,'can_delete',m.author_user_id=viewer,'can_moderate',event_space.can_moderate(m.experience_id,viewer))
FROM chat.messages m CROSS JOIN LATERAL(SELECT m.body IS NOT NULL AND m.deleted_at IS NULL AND m.moderation_status='VISIBLE' AND m.created_at>now()-interval '90 days' AND event_space.can_read(m.experience_id,m.author_user_id) AND social.connected(m.author_user_id,viewer) AS allowed) v
WHERE m.id=mid AND event_space.can_read(m.experience_id,viewer)
$$;
-- +goose StatementEnd
-- +goose Down
DROP TRIGGER chat_policy_members ON participation.members;
DROP TRIGGER chat_policy_users ON identity.users;
DROP TRIGGER chat_policy_sessions ON identity.sessions;
DROP TRIGGER chat_policy_experiences ON experiences.experiences;
DROP TRIGGER chat_policy_blocks ON social.blocks;
DROP TRIGGER chat_policy_restrictions ON social.restrictions;
DROP TRIGGER chat_policy_spaces ON event_space.settings;
DROP TRIGGER chat_policy_local ON event_space.restrictions;
DROP TRIGGER chat_policy_roles ON event_space.moderators;
DROP TRIGGER chat_policy_publish ON experiences.publishing_restrictions;
DELETE FROM social.reports WHERE target_type='CHAT_MESSAGE';
ALTER TABLE social.reports DROP CONSTRAINT reports_target_type_check;
ALTER TABLE social.reports ADD CONSTRAINT reports_target_type_check CHECK(target_type IN ('USER','POST','COMMENT'));
DROP SCHEMA chat CASCADE;

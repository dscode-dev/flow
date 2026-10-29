-- +goose Up
CREATE SCHEMA identity;
CREATE TABLE identity.users (
 id uuid PRIMARY KEY,
 status text NOT NULL DEFAULT 'active' CHECK(status IN ('active','suspended','disabled','deleted')),
 created_at timestamptz NOT NULL DEFAULT now(),
 updated_at timestamptz NOT NULL DEFAULT now(),
 last_authenticated_at timestamptz,
 onboarding_completed_at timestamptz
);
CREATE TABLE identity.profiles (
 user_id uuid PRIMARY KEY REFERENCES identity.users(id),
 display_name text NOT NULL DEFAULT '' CHECK(char_length(display_name)<=80),
 handle text UNIQUE CHECK(handle ~ '^[a-z][a-z0-9_]{2,29}$'),
 avatar_ref uuid,
 created_at timestamptz NOT NULL DEFAULT now(),
 updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE identity.reserved_handles(handle text PRIMARY KEY);
INSERT INTO identity.reserved_handles VALUES ('admin'),('administrator'),('administrador'),('flow'),('support'),('suporte'),('security'),('seguranca'),('moderator'),('moderador'),('api'),('www'),('root'),('official'),('oficial');
CREATE TABLE identity.auth_identities (
 id uuid PRIMARY KEY,
 user_id uuid NOT NULL REFERENCES identity.users(id),
 provider text NOT NULL CHECK(provider IN ('PHONE','GOOGLE','APPLE')),
 provider_subject text NOT NULL CHECK(length(provider_subject) BETWEEN 1 AND 255),
 verified_at timestamptz NOT NULL DEFAULT now(),
 created_at timestamptz NOT NULL DEFAULT now(),
 updated_at timestamptz NOT NULL DEFAULT now(),
 revoked_at timestamptz,
 UNIQUE(provider,provider_subject)
);
CREATE INDEX auth_identities_user ON identity.auth_identities(user_id);
CREATE TABLE identity.devices (
 id uuid PRIMARY KEY,
 user_id uuid NOT NULL REFERENCES identity.users(id),
 platform text NOT NULL CHECK(platform IN ('android','ios')),
 app_version text NOT NULL CHECK(length(app_version) BETWEEN 1 AND 32),
 label text NOT NULL DEFAULT '' CHECK(char_length(label)<=80),
 first_seen_at timestamptz NOT NULL DEFAULT now(),
 last_seen_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE(id,user_id)
);
CREATE TABLE identity.sessions (
 id uuid PRIMARY KEY,
 user_id uuid NOT NULL REFERENCES identity.users(id),
 device_id uuid NOT NULL,
 authenticated_provider text NOT NULL CHECK(authenticated_provider IN ('PHONE','GOOGLE','APPLE')),
 created_at timestamptz NOT NULL DEFAULT now(),
 expires_at timestamptz NOT NULL,
 last_used_at timestamptz NOT NULL DEFAULT now(),
 reauthenticated_at timestamptz NOT NULL DEFAULT now(),
 revoked_at timestamptz,
 revocation_reason text,
 FOREIGN KEY(device_id,user_id) REFERENCES identity.devices(id,user_id),
 CHECK(expires_at>created_at),
 CHECK((revoked_at IS NULL)=(revocation_reason IS NULL))
);
CREATE INDEX sessions_user ON identity.sessions(user_id,created_at DESC,id);
CREATE TABLE identity.refresh_credentials (
 id uuid PRIMARY KEY,
 session_id uuid NOT NULL REFERENCES identity.sessions(id),
 credential_hash bytea NOT NULL UNIQUE CHECK(octet_length(credential_hash)=32),
 created_at timestamptz NOT NULL DEFAULT now(),
 expires_at timestamptz NOT NULL,
 used_at timestamptz
);
CREATE INDEX refresh_session ON identity.refresh_credentials(session_id);
CREATE TABLE identity.access_credentials (
 credential_hash bytea PRIMARY KEY CHECK(octet_length(credential_hash)=32),
 session_id uuid NOT NULL REFERENCES identity.sessions(id),
 expires_at timestamptz NOT NULL
);
CREATE INDEX access_session ON identity.access_credentials(session_id);
CREATE INDEX access_expiry ON identity.access_credentials(expires_at);
CREATE TABLE identity.challenges (
 id uuid PRIMARY KEY,
 provider text NOT NULL CHECK(provider IN ('PHONE','GOOGLE','APPLE')),
 purpose text NOT NULL CHECK(purpose IN ('login','link','reauth')),
 session_id uuid REFERENCES identity.sessions(id),
 subject_ref text,
 nonce_hash bytea CHECK(nonce_hash IS NULL OR octet_length(nonce_hash)=32),
 provider_reference text,
 status text NOT NULL CHECK(status IN ('sending','pending','failed','consumed','exhausted','superseded')),
 attempts integer NOT NULL DEFAULT 0 CHECK(attempts>=0),
 created_at timestamptz NOT NULL DEFAULT now(),
 expires_at timestamptz NOT NULL,
 consumed_at timestamptz,
 origin_ref text NOT NULL,
 CHECK((purpose='login')=(session_id IS NULL)),
 CHECK((provider='PHONE' AND subject_ref IS NOT NULL AND nonce_hash IS NULL) OR (provider<>'PHONE' AND subject_ref IS NULL AND nonce_hash IS NOT NULL))
);
CREATE INDEX challenges_phone ON identity.challenges(subject_ref,created_at DESC) WHERE provider='PHONE';
CREATE INDEX challenges_expiry ON identity.challenges(expires_at);
CREATE TABLE identity.rate_limits (
 bucket_key text PRIMARY KEY,
 count integer NOT NULL CHECK(count>0),
 expires_at timestamptz NOT NULL
);
CREATE INDEX rate_limits_expiry ON identity.rate_limits(expires_at);
CREATE TABLE identity.audit_events (
 id uuid PRIMARY KEY,
 user_id uuid REFERENCES identity.users(id),
 session_id uuid,
 action text NOT NULL,
 outcome text NOT NULL CHECK(outcome IN ('success','denied','failure')),
 reason text NOT NULL DEFAULT '',
 request_id text NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX audit_user_time ON identity.audit_events(user_id,created_at DESC);
CREATE TABLE identity.provider_notifications (
 digest bytea PRIMARY KEY CHECK(octet_length(digest)=32),
 received_at timestamptz NOT NULL DEFAULT now()
);

-- +goose Down
DROP SCHEMA identity CASCADE;

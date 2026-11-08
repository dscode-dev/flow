-- +goose Up
CREATE INDEX experiences_public_recent ON experiences.experiences(created_at DESC,id DESC)
 WHERE status='PUBLISHED' AND visibility='PUBLIC' AND moderation_status='VISIBLE';

-- +goose Down
DROP INDEX experiences.experiences_public_recent;

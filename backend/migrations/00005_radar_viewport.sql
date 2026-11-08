-- +goose Up
-- Viewport envelopes are planar lon/lat rectangles, not geodesic polygons.
CREATE INDEX experiences_public_viewport ON experiences.experiences USING gist((point::geometry))
 WHERE status='PUBLISHED' AND visibility='PUBLIC' AND moderation_status='VISIBLE';

-- +goose Down
DROP INDEX experiences.experiences_public_viewport;

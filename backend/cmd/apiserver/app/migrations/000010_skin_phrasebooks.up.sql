-- M9: each skin's clips decide which actions and moods its friend's phrasebook uses, and picking a skin
-- regenerates the phrasebook before the switch applies.
ALTER TABLE skin ADD COLUMN clips JSONB NOT NULL DEFAULT '[]'; -- "wave", "wave/grumpy"; [] = the built-in vocabulary

-- reason 'reskin' writes a phrasebook for skin_id (NULL = the built-in skin) and switches to it once ready.
-- status 'abandoned' ends a job for good: a failed or superseded reskin.
-- No foreign key: skins are never deleted, and SET NULL would silently mean the built-in skin.
ALTER TABLE personality_version ADD COLUMN skin_id VARCHAR(40);

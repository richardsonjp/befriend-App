DELETE FROM personality_version WHERE reason = 'reskin' AND status <> 'ready';
UPDATE personality_version SET reason = 'evolution' WHERE reason = 'reskin';
ALTER TABLE personality_version DROP COLUMN skin_id;
ALTER TABLE skin DROP COLUMN clips;

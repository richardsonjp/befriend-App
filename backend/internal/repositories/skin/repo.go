package skin

import (
	"context"

	"befriend/internal/model"
	"befriend/pkg/clients/db"
	"befriend/pkg/utils/errors"
)

// publishSQL returns the new version only when the archive changed: an identical one matches no row to update.
// The name is inside the archive (manifest.json), so renaming a skin changes its sha256 too.
const publishSQL = `
INSERT INTO skin (id, name, version, sha256, archive, clips, artist_user_id)
VALUES (@id, @name, 1, @sha256, @archive, @clips, @artist)
ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, version = skin.version + 1, sha256 = EXCLUDED.sha256,
    archive = EXCLUDED.archive, clips = EXCLUDED.clips,
    artist_user_id = COALESCE(EXCLUDED.artist_user_id, skin.artist_user_id), updated_at = NOW()
WHERE skin.sha256 <> EXCLUDED.sha256
  AND (EXCLUDED.artist_user_id IS NULL OR skin.artist_user_id = EXCLUDED.artist_user_id)
RETURNING version`

func (r *skinRepo) ListGranted(ctx context.Context, userID string) ([]model.SkinSummary, error) {
	var skins []model.SkinSummary
	err := r.dbdget.Get(ctx).Raw(`
SELECT s.id, s.name, s.version, s.sha256, octet_length(s.archive) AS size
FROM skin s JOIN skin_grant g ON g.skin_id = s.id
WHERE g.user_id = ?
ORDER BY s.name, s.id`, userID).Scan(&skins).Error
	return skins, err
}

func (r *skinRepo) GetGranted(ctx context.Context, userID, skinID string) (*model.Skin, error) {
	m := &model.Skin{}
	q := r.dbdget.Get(ctx).Raw(`
SELECT s.* FROM skin s JOIN skin_grant g ON g.skin_id = s.id
WHERE g.user_id = ? AND s.id = ?`, userID, skinID).Scan(m)
	if q.Error != nil {
		return nil, q.Error
	}
	if q.RowsAffected == 0 {
		return nil, errors.From("DATA_NOT_FOUND")
	}
	return m, nil
}

func (r *skinRepo) Publish(ctx context.Context, m model.Skin) (int, bool, error) {
	var versions []int
	err := r.dbdget.Get(ctx).
		Raw(publishSQL, map[string]interface{}{"id": m.ID, "name": m.Name, "sha256": m.SHA256, "archive": m.Archive, "clips": m.Clips, "artist": m.ArtistUserID}).
		Scan(&versions).Error
	if err != nil || len(versions) == 1 {
		return firstOrZero(versions), err == nil, err
	}
	// Nothing changed, or an artist's upload met a skin that isn't theirs (checked in the same statement, so two
	// artists racing on a new id can't take each other's).
	var rows []model.Skin
	if err := r.dbdget.Get(ctx).Raw(`SELECT version, sha256, artist_user_id FROM skin WHERE id = ?`, m.ID).Scan(&rows).Error; err != nil {
		return 0, false, err
	}
	if len(rows) == 1 && rows[0].SHA256 != m.SHA256 {
		return 0, false, errors.From("SKIN_TAKEN")
	}
	if len(rows) == 0 {
		return 0, false, nil
	}
	return rows[0].Version, false, nil
}

func (r *skinRepo) GetClips(ctx context.Context, skinID string) ([]string, error) {
	var rows []model.Skin
	if err := r.dbdget.Get(ctx).Raw(`SELECT clips FROM skin WHERE id = ?`, skinID).Scan(&rows).Error; err != nil {
		return nil, err
	}
	if len(rows) == 0 {
		return nil, errors.From("DATA_NOT_FOUND")
	}
	return rows[0].Clips.Data, nil
}

func (r *skinRepo) Grant(ctx context.Context, userID, skinID string) (bool, error) {
	q := r.dbdget.Get(ctx).
		Exec(`INSERT INTO skin_grant (user_id, skin_id) VALUES (?, ?) ON CONFLICT DO NOTHING`, userID, skinID)
	if db.IsForeignKeyViolation(q.Error) {
		return false, errors.From("DATA_NOT_FOUND")
	}
	return q.RowsAffected > 0, q.Error
}

func (r *skinRepo) Revoke(ctx context.Context, userID, skinID string) (bool, error) {
	q := r.dbdget.Get(ctx).Exec(`DELETE FROM skin_grant WHERE user_id = ? AND skin_id = ?`, userID, skinID)
	return q.RowsAffected > 0, q.Error
}

func (r *skinRepo) NotifyUser(ctx context.Context, userID string) error {
	return r.dbdget.Get(ctx).Exec(`SELECT pg_notify(?, ?)`, NotifyChannel, userID).Error
}

func (r *skinRepo) NotifySelected(ctx context.Context, skinID string) error {
	return r.dbdget.Get(ctx).
		Exec(`SELECT pg_notify(?, id::text) FROM "user" WHERE skin_id = ?`, NotifyChannel, skinID).Error
}

func firstOrZero(values []int) int {
	if len(values) == 0 {
		return 0
	}
	return values[0]
}

package skin

import (
	"context"
	"time"

	"befriend/internal/model"
	"befriend/pkg/utils/errors"
)

// submissionColumns are a submission without its archive.
const submissionColumns = "id, artist_user_id, skin_id, name, status, note, created_at, reviewed_at"

// CountPendingSubmissions also locks the artist's submissions until the transaction ends, so concurrent uploads
// can't all see room under the cap.
func (r *skinRepo) CountPendingSubmissions(ctx context.Context, artistID string) (int64, error) {
	if err := r.dbdget.Get(ctx).Exec(`SELECT pg_advisory_xact_lock(hashtext(?))`, "skin_submission:"+artistID).Error; err != nil {
		return 0, err
	}
	var n int64
	err := r.dbdget.Get(ctx).Model(&model.SkinSubmission{}).
		Where("artist_user_id = ? AND status = ?", artistID, model.SubmissionPending).Count(&n).Error
	return n, err
}

func (r *skinRepo) CreateSubmission(ctx context.Context, m *model.SkinSubmission) error {
	return r.dbdget.Get(ctx).Create(m).Error
}

func (r *skinRepo) ListSubmissions(ctx context.Context, artistID *string, status string, limit int) ([]model.SkinSubmission, error) {
	var out []model.SkinSubmission
	q := r.dbdget.Get(ctx).Select(submissionColumns).Order("created_at DESC").Limit(limit)
	if artistID != nil {
		q = q.Where("artist_user_id = ?", *artistID)
	}
	if status != "" {
		q = q.Where("status = ?", status)
	}
	return out, q.Find(&out).Error
}

func (r *skinRepo) GetSubmission(ctx context.Context, id string) (*model.SkinSubmission, error) {
	var out []model.SkinSubmission
	if err := r.dbdget.Get(ctx).Where("id = ?", id).Limit(1).Find(&out).Error; err != nil {
		return nil, err
	}
	if len(out) == 0 {
		return nil, errors.From("DATA_NOT_FOUND")
	}
	return &out[0], nil
}

// ReviewSubmission records the outcome of a pending submission; DATA_CONFLICT when it was already reviewed.
func (r *skinRepo) ReviewSubmission(ctx context.Context, id, status string, note *string, now time.Time) error {
	q := r.dbdget.Get(ctx).Model(&model.SkinSubmission{}).
		Where("id = ? AND status = ?", id, model.SubmissionPending).
		Updates(map[string]interface{}{"status": status, "note": note, "reviewed_at": now})
	if q.Error != nil {
		return q.Error
	}
	if q.RowsAffected == 0 {
		return errors.From("DATA_CONFLICT").WithDetail("the submission was already reviewed")
	}
	return nil
}

// GetArtist returns who made a published skin: found false when it isn't published, a nil artist when it was
// published from the repo.
func (r *skinRepo) GetArtist(ctx context.Context, skinID string) (artist *string, found bool, err error) {
	var rows []model.Skin
	if err := r.dbdget.Get(ctx).Raw(`SELECT artist_user_id FROM skin WHERE id = ?`, skinID).Scan(&rows).Error; err != nil {
		return nil, false, err
	}
	if len(rows) == 0 {
		return nil, false, nil
	}
	return rows[0].ArtistUserID, true, nil
}

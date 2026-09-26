package skin

import (
	"context"
	"time"
	"unicode/utf8"

	"befriend/internal/model"
	"befriend/pkg/skinpack"
	"befriend/pkg/utils/errors"
)

const (
	maxPendingSubmissions = 3
	maxListedSubmissions  = 100
	maxNoteLength         = 500
)

type SubmissionResponse struct {
	ID         string     `json:"id"`
	SkinID     string     `json:"skin_id"`
	Name       string     `json:"name"`
	Status     string     `json:"status"` // pending | approved | rejected
	Note       *string    `json:"note"`   // why it was rejected
	ArtistID   string     `json:"-"`
	CreatedAt  time.Time  `json:"created_at"`
	ReviewedAt *time.Time `json:"reviewed_at"`
}

func (s *skinService) Submit(ctx context.Context, userID, skinID string, upload []byte) (*SubmissionResponse, error) {
	artist, err := s.userService.GetUserByID(ctx, userID)
	if err != nil {
		return nil, err
	}
	if !artist.IsArtist {
		return nil, errors.From("NOT_AN_ARTIST") // before the upload costs any work
	}
	// Unzipping and decoding happen outside the transaction, so they don't hold a connection.
	pkg, err := skinpack.FromUpload(upload, skinID)
	if err != nil {
		return nil, errors.From("SKIN_INVALID").WithDetail(err.Error())
	}
	var response *SubmissionResponse
	err = s.txRepo.Run(ctx, func(ctx context.Context) error {
		pending, err := s.skinRepo.CountPendingSubmissions(ctx, userID)
		if err != nil {
			return err
		}
		if pending >= maxPendingSubmissions {
			return errors.From("TOO_MANY_SUBMISSIONS")
		}
		if err := s.checkOwner(ctx, userID, skinID); err != nil {
			return err
		}
		m := &model.SkinSubmission{ArtistUserID: userID, SkinID: skinID, Name: pkg.Name, Archive: upload}
		if err := s.skinRepo.CreateSubmission(ctx, m); err != nil {
			return err
		}
		m.Status = model.SubmissionPending
		response = toSubmission(*m)
		return nil
	})
	return response, err
}

// checkOwner lets an artist use a new skin id, or one they already published; a skin published from the repo
// or by another artist is taken.
func (s *skinService) checkOwner(ctx context.Context, userID, skinID string) error {
	if !idPattern.MatchString(skinID) {
		return errors.From("SKIN_INVALID").WithDetail("skin id: use 1-40 of a-z, 0-9 and -")
	}
	owner, published, err := s.skinRepo.GetArtist(ctx, skinID)
	if err != nil || !published {
		return err
	}
	if owner == nil || *owner != userID {
		return errors.From("SKIN_TAKEN")
	}
	return nil
}

func (s *skinService) ListSubmissions(ctx context.Context, userID *string) ([]SubmissionResponse, error) {
	status := ""
	if userID == nil {
		status = model.SubmissionPending
	}
	rows, err := s.skinRepo.ListSubmissions(ctx, userID, status, maxListedSubmissions)
	if err != nil {
		return nil, err
	}
	out := make([]SubmissionResponse, 0, len(rows))
	for _, m := range rows {
		out = append(out, *toSubmission(m))
	}
	return out, nil
}

func (s *skinService) GetSubmission(ctx context.Context, id string) (*model.SkinSubmission, error) {
	m, err := s.skinRepo.GetSubmission(ctx, id)
	if errors.Is(err, "DATA_NOT_FOUND") {
		return nil, errors.From("SUBMISSION_NOT_FOUND")
	}
	return m, err
}

func (s *skinService) Approve(ctx context.Context, id string) (*skinpack.Package, int, error) {
	m, err := s.GetSubmission(ctx, id)
	if err != nil {
		return nil, 0, err
	}
	pkg, err := skinpack.FromUpload(m.Archive, m.SkinID)
	if err != nil {
		return nil, 0, errors.From("SKIN_INVALID").WithDetail(err.Error())
	}
	var version int
	err = s.txRepo.Run(ctx, func(ctx context.Context) error {
		// Checked again (and by Publish, atomically): another artist's skin may have been published under the id.
		if err := s.checkOwner(ctx, m.ArtistUserID, m.SkinID); err != nil {
			return err
		}
		if err := s.skinRepo.ReviewSubmission(ctx, id, model.SubmissionApproved, nil, time.Now()); err != nil {
			return err
		}
		version, _, err = s.Publish(ctx, pkg, &m.ArtistUserID)
		return err
	})
	return pkg, version, err
}

func (s *skinService) Reject(ctx context.Context, id, note string) error {
	if utf8.RuneCountInString(note) > maxNoteLength {
		return errors.From("BAD_REQUEST").WithDetail("the note is at most 500 characters")
	}
	if _, err := s.GetSubmission(ctx, id); err != nil {
		return err
	}
	return s.skinRepo.ReviewSubmission(ctx, id, model.SubmissionRejected, &note, time.Now())
}

func (s *skinService) SetArtist(ctx context.Context, payload GrantPayload, artist bool) error {
	userID, err := s.resolveUser(ctx, payload)
	if err != nil {
		return err
	}
	return s.userService.SetArtist(ctx, userID, artist)
}

func toSubmission(m model.SkinSubmission) *SubmissionResponse {
	return &SubmissionResponse{
		ID: m.ID, SkinID: m.SkinID, Name: m.Name, Status: m.Status, Note: m.Note, ArtistID: m.ArtistUserID,
		CreatedAt: m.CreatedAt, ReviewedAt: m.ReviewedAt,
	}
}

package model

import "time"

// TableName overrides the table name used by SkinSubmission to `skin_submission`
func (SkinSubmission) TableName() string {
	return "skin_submission"
}

// Submission statuses.
const (
	SubmissionPending  = "pending"
	SubmissionApproved = "approved"
	SubmissionRejected = "rejected"
)

// SkinSubmission is an artist's upload waiting for review, or its outcome.
type SkinSubmission struct {
	ID           string     `gorm:"primarykey;default:gen_random_uuid()"`
	ArtistUserID string     `gorm:"column:artist_user_id"`
	SkinID       string     `gorm:"column:skin_id"`
	Name         string     `gorm:"column:name"`
	Archive      []byte     `gorm:"column:archive"`
	Status       string     `gorm:"column:status;default:pending"`
	Note         *string    `gorm:"column:note"`
	CreatedAt    time.Time  `gorm:"column:created_at;default:now()"`
	ReviewedAt   *time.Time `gorm:"column:reviewed_at"`
}

package model

import (
	"time"
)

// TableName overrides the table name used by KycRequest to `kyc_request`
func (KycRequest) TableName() string {
	return "kyc_request"
}

type KycRequest struct {
	ID                    string      `gorm:"primarykey;default:gen_random_uuid()"`
	AccountID             string      `gorm:"column:account_id;not null"`
	Type                  string      `gorm:"column:type;not null"`
	PrimaryIDNumber       string      `gorm:"column:primary_id_number"`
	LegalName             string      `gorm:"column:legal_name"`
	EntityData            interface{} `gorm:"column:entity_data;type:jsonb;not null;default:'{}'"`
	Documents             interface{} `gorm:"column:documents;type:jsonb;not null;default:'{}'"`
	SectionFeedback       interface{} `gorm:"column:section_feedback;type:jsonb;default:'{}'"`
	Status                string      `gorm:"column:status;default:'PENDING'"`
	GlobalRejectionReason string      `gorm:"column:global_rejection_reason"`
	ReviewedByOperatorID  string      `gorm:"column:reviewed_by_operator_id"`
	SubmittedAt           time.Time   `gorm:"column:submitted_at;type:datetime;default:now()"`
	ReviewedAt            *time.Time  `gorm:"column:reviewed_at;type:datetime"`
}

package model

import (
	"time"
)

// TableName overrides the table name used by OperatorAuditLog to `operator_audit_log`
func (OperatorAuditLog) TableName() string {
	return "operator_audit_log"
}

type OperatorAuditLog struct {
	ID          string      `gorm:"primarykey;default:gen_random_uuid()"`
	OperatorID  string      `gorm:"column:operator_id"`
	Action      string      `gorm:"column:action;not null"`
	TargetTable string      `gorm:"column:target_table"`
	TargetID    string      `gorm:"column:target_id"`
	Details     interface{} `gorm:"column:details;type:jsonb"`
	CreatedAt   time.Time   `gorm:"column:created_at;type:datetime;default:now()"`
}

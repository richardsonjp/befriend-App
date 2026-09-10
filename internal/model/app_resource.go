package model

import (
	"time"
)

// TableName overrides the table name used by AppResource to `app_resource`
func (AppResource) TableName() string {
	return "app_resource"
}

type AppResource struct {
	ID                   string    `gorm:"primarykey;default:gen_random_uuid()"`
	Type                 string    `gorm:"column:type;not null"` // FRONTEND/BACKEND
	PathPattern          string    `gorm:"column:path_pattern;not null"`
	Method               string    `gorm:"column:method"`
	Name                 string    `gorm:"column:name"`
	RequiredPermissionID string    `gorm:"column:required_permission_id"`
	CreatedAt            time.Time `gorm:"column:created_at;type:datetime;default:now()"`
}

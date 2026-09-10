package model

import "go-skeleton/internal/model/enum"

// TableName overrides the table name used by PermissionCategory to `permission_category`
func (PermissionCategory) TableName() string {
	return "permission_category"
}

type TargetUserType = enum.UserType

type PermissionCategory struct {
	ID             string         `gorm:"primarykey;default:gen_random_uuid()"`
	Name           string         `gorm:"column:name;not null;uniqueIndex:idx_name_target_user_type"`
	Description    string         `gorm:"column:description"`
	Icon           string         `gorm:"column:icon"`
	TargetUserType TargetUserType `gorm:"column:target_user_type;uniqueIndex:idx_name_target_user_type"`
	DisplayOrder   int            `gorm:"column:display_order;default:0"`
}

package model

// TableName overrides the table name used by RolePermission to `role_permission`
func (RolePermission) TableName() string {
	return "role_permission"
}

type RolePermission struct {
	RoleID       string `gorm:"primarykey;column:role_id"`
	PermissionID string `gorm:"primarykey;column:permission_id"`
}

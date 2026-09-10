package model

// TableName overrides the table name used by Role to `role`
func (Role) TableName() string {
	return "role"
}

type Role struct {
	ID           string `gorm:"primarykey;default:gen_random_uuid()"`
	AccountID    string `gorm:"column:account_id"`
	Name         string `gorm:"column:name;not null"`
	Description  string `gorm:"column:description"`
	IsSystemRole bool   `gorm:"column:is_system_role;default:false"`
}

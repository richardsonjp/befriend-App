package model

import (
	"befriend/internal/model/enum"
	"time"
)

// TableName overrides the table name used by Account to `account`
func (Account) TableName() string {
	return "account"
}

type AccountType = enum.AccountType
type Account struct {
	ID        string      `gorm:"primarykey;default:gen_random_uuid()"`
	Type      AccountType `gorm:"column:type;not null"` // PERSONAL/CORPORATE
	Name      string      `gorm:"column:name"`
	IsFrozen  bool        `gorm:"column:is_frozen;default:false"`
	KycLevel  int         `gorm:"column:kyc_level;default:0"`
	CreatedAt time.Time   `gorm:"column:created_at;type:datetime;default:now()"`
	UpdatedAt time.Time   `gorm:"column:updated_at;type:datetime;default:now()"`
}

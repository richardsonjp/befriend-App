package model

import "time"

// TableName overrides the table name used by Skin to `skin`
func (Skin) TableName() string {
	return "skin"
}

// Skin is one published character skin: the zip the apps download (manifest.json, skin.json, stills, minis).
type Skin struct {
	ID        string    `gorm:"primarykey;column:id"`
	Name      string    `gorm:"column:name"`
	Version   int       `gorm:"column:version"`
	SHA256    string    `gorm:"column:sha256"`
	Archive   []byte    `gorm:"column:archive"`
	CreatedAt time.Time `gorm:"column:created_at"`
	UpdatedAt time.Time `gorm:"column:updated_at"`
}

// SkinSummary is a skin without its archive.
type SkinSummary struct {
	ID      string `gorm:"column:id"`
	Name    string `gorm:"column:name"`
	Version int    `gorm:"column:version"`
	SHA256  string `gorm:"column:sha256"`
	Size    int    `gorm:"column:size"`
}

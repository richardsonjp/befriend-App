package model

import (
	"time"

	ct "befriend/internal/model/custom_type"
)

// TableName overrides the table name used by Skin to `skin`
func (Skin) TableName() string {
	return "skin"
}

// Skin is one published character skin: the zip the apps download (manifest.json, frames, minis).
type Skin struct {
	ID      string `gorm:"primarykey;column:id"`
	Name    string `gorm:"column:name"`
	Version int    `gorm:"column:version"`
	SHA256  string `gorm:"column:sha256"`
	Archive []byte `gorm:"column:archive"`
	// Clips are its animations ("wave", "wave/grumpy"): what its friend's phrasebook may use.
	Clips ct.JSONB[[]string] `gorm:"column:clips"`
	// ArtistUserID made it (nil: published from the repo); only they can submit a new version.
	ArtistUserID *string `gorm:"column:artist_user_id"`
	// Tier and ProductID are set while it's for sale; Preview is idle's first frame for the shop.
	Tier      *int      `gorm:"column:tier"`
	ProductID *string   `gorm:"column:product_id"`
	Preview   []byte    `gorm:"column:preview"`
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

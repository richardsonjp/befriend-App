package model

import (
	"time"
)

// TableName overrides the table name used by Friend to `friend`
func (Friend) TableName() string {
	return "friend"
}

type Friend struct {
	ID               string    `gorm:"primarykey;default:gen_random_uuid()"`
	UserID           string    `gorm:"column:user_id"`
	Name             string    `gorm:"column:name"`
	UserNickname     string    `gorm:"column:user_nickname"`
	BornAt           time.Time `gorm:"column:born_at"`
	BirthCity        *string   `gorm:"column:birth_city"`
	BirthCountry     *string   `gorm:"column:birth_country"`
	BirthLat         *float64  `gorm:"column:birth_lat"`
	BirthLon         *float64  `gorm:"column:birth_lon"`
	BirthTZ          string    `gorm:"column:birth_tz"`
	WesternSign      string    `gorm:"column:western_sign"`
	ChineseAnimal    string    `gorm:"column:chinese_animal"`
	ChineseElement   string    `gorm:"column:chinese_element"`
	ChinesePolarity  string    `gorm:"column:chinese_polarity"`
	FengShuiStar     int       `gorm:"column:feng_shui_star"`
	FengShuiElement  string    `gorm:"column:feng_shui_element"`
	CurrentVersionID *string   `gorm:"column:current_version_id"`
	NextEvolutionAt  time.Time `gorm:"column:next_evolution_at"`
	CreatedAt        time.Time `gorm:"column:created_at;default:now()"`
	UpdatedAt        time.Time `gorm:"column:updated_at;default:now()"`
}

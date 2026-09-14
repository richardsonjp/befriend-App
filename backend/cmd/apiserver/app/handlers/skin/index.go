package skin

import (
	serviceSkin "befriend/internal/services/skin"
)

type SkinHandler struct {
	skinService serviceSkin.SkinService
}

func NewSkinHandler(skinService serviceSkin.SkinService) *SkinHandler {
	return &SkinHandler{
		skinService: skinService,
	}
}

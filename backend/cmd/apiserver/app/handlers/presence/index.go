package presence

import (
	servicePresence "befriend/internal/services/presence"
)

type PresenceHandler struct {
	presenceService servicePresence.PresenceService
}

func NewPresenceHandler(presenceService servicePresence.PresenceService) *PresenceHandler {
	return &PresenceHandler{
		presenceService: presenceService,
	}
}

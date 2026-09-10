package trigger_event

import (
	serviceTriggerEvent "befriend/internal/services/trigger_event"
)

type TriggerEventHandler struct {
	triggerEventService serviceTriggerEvent.TriggerEventService
}

func NewTriggerEventHandler(triggerEventService serviceTriggerEvent.TriggerEventService) *TriggerEventHandler {
	return &TriggerEventHandler{
		triggerEventService: triggerEventService,
	}
}

package friend

import (
	"befriend/internal/services/friend"
	"befriend/internal/services/personality"
)

type FriendHandler struct {
	friendService      friend.FriendService
	personalityService personality.PersonalityService
}

func NewFriendHandler(friendService friend.FriendService, personalityService personality.PersonalityService) *FriendHandler {
	return &FriendHandler{
		friendService:      friendService,
		personalityService: personalityService,
	}
}

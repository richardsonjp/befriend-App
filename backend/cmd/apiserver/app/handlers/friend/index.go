package friend

import (
	"befriend/internal/services/friend"
)

type FriendHandler struct {
	friendService friend.FriendService
}

func NewFriendHandler(friendService friend.FriendService) *FriendHandler {
	return &FriendHandler{
		friendService: friendService,
	}
}

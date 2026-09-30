package chat_sync

import (
	serviceChatSync "befriend/internal/services/chat_sync"
)

type ChatSyncHandler struct {
	chatSyncService serviceChatSync.ChatSyncService
}

func NewChatSyncHandler(chatSyncService serviceChatSync.ChatSyncService) *ChatSyncHandler {
	return &ChatSyncHandler{
		chatSyncService: chatSyncService,
	}
}

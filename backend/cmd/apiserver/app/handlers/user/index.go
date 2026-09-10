package user

import (
	"befriend/internal/services/user_application"
)

type UserHandler struct {
	userApplicationService user_application.UserApplicationService
}

func NewUserHandler(userApplicationService user_application.UserApplicationService) *UserHandler {
	return &UserHandler{
		userApplicationService: userApplicationService,
	}
}

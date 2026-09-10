package authentication

// Login contains credentials for user authentication
type Login struct {
	Email    string `json:"email" validate:"required,email"`
	Password string `json:"password" validate:"required"`
}

type LogoutPayload struct {
	UserID string `json:"user_id"`
	RoleID string `json:"role_id"`
}

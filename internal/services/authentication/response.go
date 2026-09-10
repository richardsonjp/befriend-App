package authentication

type AuthenticateSessionResponse struct {
	AccessToken  string   `json:"access_token"`
	RefreshToken string   `json:"refresh_token"`
	FrontendPath []string `json:"frontend_path"`
}

type SessionData struct {
	User UserResponse
	Role RoleResponse
}

type UserProfile struct {
	Name  string `json:"name"`
	Email string `json:"email"`
	Phone string `json:"phone"`
}

type FrontendPathResponse struct {
	FrontendPath []string `json:"frontend_path"`
}

type HomeProfile struct {
	User UserResponse `json:"user"`
	Role RoleResponse `json:"role"`
}

type UserResponse struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	Email    string `json:"email"`
	Phone    string `json:"phone"`
	RoleID   string `json:"role_id"`
	Status   string `json:"status"`
	Password string `json:"-"`
}

type RoleResponse struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

// RegisterResponse contains the response data after successful registration
type RegisterResponse struct {
	UserID   string `json:"user_id"`
	TenantID uint   `json:"tenant_id"` // Deprecated/Legacy
	Name     string `json:"name"`
	Email    string `json:"email"`
	Phone    string `json:"phone"`
	Status   string `json:"status"`
	Role     string `json:"role"`
	Message  string `json:"message"`
}

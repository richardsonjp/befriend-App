package account_member

type CreatePayload struct {
	AccountID string `json:"type"`
	UserID    string `json:"name"`
	RoleID    string `json:"role_id"`
}

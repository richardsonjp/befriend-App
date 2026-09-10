package role

type CreatePayload struct {
	AccountID    string
	Name         string `json:"name" validate:"required,min=3,max=50"`
	Description  string `json:"description" validate:"required,max=255"`
	IsSystemRole bool   `json:"is_system_role"`
}

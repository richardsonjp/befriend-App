package account

type CreatePayload struct {
	Type string `json:"type" validate:"required"`
	Name string `json:"name" validate:"required"`
}

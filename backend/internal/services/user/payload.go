package user

type CreatePayload struct {
	Email    string `json:"email" validate:"required,email,max=255"`
	Password string `json:"password" validate:"required,min=8,max=72"` // bcrypt only reads 72 bytes
}

package user_application

// RegisterPayload contains all data needed for email/password registration
type RegisterPayload struct {
	Email    string `json:"email" validate:"required,email,max=255"`
	Password string `json:"password" validate:"required,min=8,max=72"` // bcrypt only reads 72 bytes
}

type VerifyEmailPayload struct {
	Email   string `json:"email" validate:"required,email,max=255"`
	OTPCode string `json:"otp_code" validate:"required,len=6,numeric"`
}

type ResendCodePayload struct {
	Email string `json:"email" validate:"required,email,max=255"`
}

package user_application

// RegisterPayload contains all data needed for user registration
type RegisterPayload struct {
	// Account information
	AccountType string `json:"account_type" validate:"omitempty,oneof=personal corporate"`
	AccountName string `json:"account_name" validate:"required_if=AccountType corporate,max=100"`

	// User information
	FullName    string `json:"full_name" validate:"required,min=3,max=255"`
	Email       string `json:"email" validate:"required,email,min=8,max=255"`
	PhoneNumber string `json:"phone_number" validate:"required,min=10,max=20"`
	Password    string `json:"password" validate:"required,min=8,max=100"`
}

type VerifyEmailPayload struct {
	Email   string `json:"email" validate:"required,email,min=8,max=255"`
	OTPCode string `json:"otp_code" validate:"required,min=6,max=6"`
}

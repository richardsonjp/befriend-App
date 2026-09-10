package user

type CreatePayload struct {
	FullName    string `json:"full_name" validate:"required,min=3,max=50"`
	Email       string `json:"email" validate:"required,email=true,min=8,max=50"`
	PhoneNumber string `json:"phone_number" validate:"required,min=10,max=15"`
	Password    string `json:"password" validate:"required,min=8"`
}

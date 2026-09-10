package device

type CreatePayload struct {
	UserID   string `json:"-"`
	Platform string `json:"platform" validate:"required,oneof=ios macos"`
	Name     string `json:"name" validate:"required,max=100"`
}

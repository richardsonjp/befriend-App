package permission_category

type CreatePayload struct {
	Name           string
	Description    string
	Icon           string
	TargetUserType string
	DisplayOrder   int
}

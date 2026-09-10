package role

type RoleDetailResponse struct {
	ID           string                        `json:"id"`
	Name         string                        `json:"name"`
	Description  string                        `json:"description"`
	IsSystemRole bool                          `json:"is_system_role"`
	Permissions  []AvailablePermissionResponse `json:"permissions"`
}

type AvailablePermissionResponse struct {
	CategoryID   string                    `json:"category_id"`
	CategoryName string                    `json:"category_name"`
	Permissions  []AvailablePermissionItem `json:"permissions"`
}

type AvailablePermissionItem struct {
	ID         string `json:"id"`
	Code       string `json:"code"`
	Name       string `json:"name"`
	IsAssigned bool   `json:"is_assigned"`
}

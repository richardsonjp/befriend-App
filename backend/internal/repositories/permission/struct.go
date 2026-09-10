package permission

// PermissionWithAssignment holds permission details with an assignment flag
type PermissionWithAssignment struct {
	ID           string
	Code         string
	Name         string
	CategoryID   string
	CategoryName string
	IsAssigned   bool
}

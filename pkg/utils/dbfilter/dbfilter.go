package dbfilter

import (
	"fmt"
	"strings"

	"gorm.io/gorm"
)

// ApplyFilters applies search + direct field filters to a GORM query.
// searchableColumns → columns that accept fuzzy search
// filters[key] = value from HTTP or service layer
//
// Example filters: search, status, email, role_name, etc.
func ApplyFilters(db *gorm.DB, tableName string, searchableColumns []string, filters map[string]string) *gorm.DB {

	// SEARCH (LIKE %value%)
	if rawSearch, ok := filters["search"]; ok {
		search := strings.TrimSpace(rawSearch)
		if search != "" && len(searchableColumns) > 0 {
			like := "%" + search + "%"

			var parts []string
			var params []interface{}

			for _, col := range searchableColumns {
				parts = append(parts, fmt.Sprintf(`%s.%s ILIKE ?`, tableName, col))
				params = append(params, like)
			}

			searchSQL := "(" + strings.Join(parts, " OR ") + ")"
			db = db.Where(searchSQL, params...)
		}
	}

	// SIMPLE EQUAL FILTERS — status, plan, etc.
	for k, v := range filters {
		if k == "search" || v == "" {
			continue
		}
		// safe: column exists on the table
		db = db.Where(fmt.Sprintf(`%s.%s = ?`, tableName, k), v)
	}

	return db
}

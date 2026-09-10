package middlewares

import (
	"testing"

	"github.com/stretchr/testify/assert"
)

func TestMatchPath(t *testing.T) {
	tests := []struct {
		name    string
		pattern string
		path    string
		want    bool
	}{
		{
			name:    "exact match",
			pattern: "/api/users",
			path:    "/api/users",
			want:    true,
		},
		{
			name:    "single parameter match",
			pattern: "/api/users/:id",
			path:    "/api/users/123",
			want:    true,
		},
		{
			name:    "multiple parameters match",
			pattern: "/api/:category/:id",
			path:    "/api/books/123",
			want:    true,
		},
		{
			name:    "parameter in middle",
			pattern: "/api/users/:id/details",
			path:    "/api/users/123/details",
			want:    true,
		},
		{
			name:    "length mismatch",
			pattern: "/api/users/:id",
			path:    "/api/users/123/details",
			want:    false,
		},
		{
			name:    "prefix mismatch",
			pattern: "/api/users",
			path:    "/api/user",
			want:    false,
		},
		{
			name:    "trailing slash handling",
			pattern: "/api/users/",
			path:    "/api/users",
			want:    true, // fiber usually normalizes, but our helper should probably handle clean equivalence if possible, relying on split logic above
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := matchPath(tt.pattern, tt.path)
			assert.Equal(t, tt.want, got)
		})
	}
}

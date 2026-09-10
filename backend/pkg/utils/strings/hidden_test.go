package strings

import "testing"

func TestIsHiddenRune(t *testing.T) {
	tests := []struct {
		name string
		r    rune
		want bool
	}{
		{"letter", 'a', false},
		{"accented letter", 'é', false},
		{"emoji", '👩', false},
		{"space", ' ', false},
		{"newline (whitespace, collapsed elsewhere)", '\n', false},
		{"tab", '\t', false},
		{"bell", '\a', true},
		{"null", '\x00', true},
		{"delete", '\x7f', true},
		{"zero-width space", '\u200b', true},
		{"right-to-left override", '\u202e', true},
		{"left-to-right isolate", '\u2066', true},
		{"byte-order mark", '\ufeff', true},
		{"zero-width joiner (emoji sequences)", '\u200d', false},
		{"variation selector-16 (emoji presentation)", '\ufe0f', false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := IsHiddenRune(tt.r); got != tt.want {
				t.Fatalf("IsHiddenRune(%U) = %v; want %v", tt.r, got, tt.want)
			}
		})
	}
}

package enum

import (
	"database/sql"
	"database/sql/driver"
	"testing"
)

// valueScanner is what GORM needs for an enum column to round-trip as text.
type valueScanner interface {
	driver.Valuer
	sql.Scanner
}

func TestEnumsRoundTripAsText(t *testing.T) {
	type entry struct {
		name  string
		value driver.Valuer // the enum being written (Scan has a pointer receiver)
		fresh valueScanner  // an empty enum to scan into
		text  string
	}
	var entries []entry
	for status, text := range UserStatusKey {
		entries = append(entries, entry{"user status " + text, status, new(UserStatus), text})
	}
	for platform, text := range DevicePlatformKey {
		entries = append(entries, entry{"device platform " + text, platform, new(DevicePlatform), text})
	}

	for _, e := range entries {
		t.Run(e.name, func(t *testing.T) {
			got, err := e.value.Value()
			if err != nil || got != e.text {
				t.Fatalf("Value() = %v, %v; want %q", got, err, e.text)
			}
			for _, raw := range []interface{}{e.text, []byte(e.text)} {
				if err := e.fresh.Scan(raw); err != nil {
					t.Fatalf("Scan(%T) error: %v", raw, err)
				}
				if back, _ := e.fresh.Value(); back != e.text {
					t.Fatalf("Scan(%T) round-tripped to %v; want %q", raw, back, e.text)
				}
			}
		})
	}
}

func TestEnumsRejectUnknownValues(t *testing.T) {
	tests := []struct {
		name string
		dest valueScanner
		raw  interface{}
	}{
		{"unknown user status", new(UserStatus), "bogus"},
		{"non-text user status", new(UserStatus), 42},
		{"unknown device platform", new(DevicePlatform), "android"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if err := tt.dest.Scan(tt.raw); err == nil {
				t.Fatalf("Scan(%v) should fail", tt.raw)
			}
		})
	}
}

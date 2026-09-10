package enum

import (
	"database/sql/driver"
	"fmt"
)

type DevicePlatform int64

// Scan for converting byte to string for fetching/read
func (s *DevicePlatform) Scan(value interface{}) error {
	key, err := scanString(value)
	if err != nil {
		return err
	}
	for i, v := range DevicePlatformKey {
		if v == key {
			*s = i
			return nil
		}
	}
	return fmt.Errorf("unknown device platform %q", key)
}

// Value for converting enum to string for storing/write
func (s DevicePlatform) Value() (driver.Value, error) {
	return s.String(), nil
}

func NewDevicePlatform(value string) DevicePlatform {
	for i, v := range DevicePlatformKey {
		if v == value {
			return i
		}
	}
	panic("enum not found")
}

const (
	IOS DevicePlatform = iota + 1
	MACOS
)

var DevicePlatformKey = map[DevicePlatform]string{
	IOS:   "ios",
	MACOS: "macos",
}

// String for stringify DevicePlatform
func (s DevicePlatform) String() string {
	return DevicePlatformKey[s]
}

package enum

import (
	"database/sql/driver"
	"fmt"
)

type UserStatus int64

// Scan for converting byte to string for fetching/read
func (s *UserStatus) Scan(value interface{}) error {
	key, err := scanString(value)
	if err != nil {
		return err
	}
	for i, v := range UserStatusKey {
		if v == key {
			*s = i
			return nil
		}
	}
	return fmt.Errorf("unknown user status %q", key)
}

// Value for converting enum to string for storing/write
func (s UserStatus) Value() (driver.Value, error) {
	return s.String(), nil
}

func NewUserStatus(value string) UserStatus {
	for i, v := range UserStatusKey {
		if v == value {
			return i
		}
	}
	panic("enum not found")
}

const (
	UNVERIFIED UserStatus = iota + 1
	ACTIVE
	SUSPENDED
	LOCKED
	DELETED
)

var UserStatusKey = map[UserStatus]string{
	UNVERIFIED: "unverified",
	ACTIVE:     "active",
	SUSPENDED:  "suspended",
	LOCKED:     "locked",
	DELETED:    "deleted",
}

// String for stringify UserStatus
func (s UserStatus) String() string {
	return UserStatusKey[s]
}

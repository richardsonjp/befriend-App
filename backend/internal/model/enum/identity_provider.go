package enum

import (
	"database/sql/driver"
	"fmt"
)

type IdentityProvider int64

// Scan for converting byte to string for fetching/read
func (s *IdentityProvider) Scan(value interface{}) error {
	key, err := scanString(value)
	if err != nil {
		return err
	}
	for i, v := range IdentityProviderKey {
		if v == key {
			*s = i
			return nil
		}
	}
	return fmt.Errorf("unknown identity provider %q", key)
}

// Value for converting enum to string for storing/write
func (s IdentityProvider) Value() (driver.Value, error) {
	return s.String(), nil
}

const (
	APPLE IdentityProvider = iota + 1
	GOOGLE
)

var IdentityProviderKey = map[IdentityProvider]string{
	APPLE:  "apple",
	GOOGLE: "google",
}

// String for stringify IdentityProvider
func (s IdentityProvider) String() string {
	return IdentityProviderKey[s]
}

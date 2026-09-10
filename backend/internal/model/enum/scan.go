package enum

import "fmt"

// scanString reads a text column as a Go string (drivers return string or []byte).
func scanString(value interface{}) (string, error) {
	switch v := value.(type) {
	case string:
		return v, nil
	case []byte:
		return string(v), nil
	default:
		return "", fmt.Errorf("enum: cannot scan %T", value)
	}
}

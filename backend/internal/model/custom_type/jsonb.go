package ct

import (
	"database/sql/driver"
	"encoding/json"
	"fmt"
)

// don't import any third party lib

// JSONB stores a typed Go value in a jsonb column.
type JSONB[T any] struct {
	Data T
}

func (j JSONB[T]) Value() (driver.Value, error) {
	b, err := json.Marshal(j.Data)
	if err != nil {
		return nil, err
	}
	return string(b), nil
}

// Scan accepts both []byte and string: drivers differ in how they return jsonb.
func (j *JSONB[T]) Scan(value interface{}) error {
	switch v := value.(type) {
	case nil:
		return nil
	case []byte:
		return json.Unmarshal(v, &j.Data)
	case string:
		return json.Unmarshal([]byte(v), &j.Data)
	default:
		return fmt.Errorf("ct.JSONB: cannot scan %T", value)
	}
}

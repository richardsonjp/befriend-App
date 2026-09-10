package enum

type UserType int64

// Scan for converting byte to string for fetching/read
func (s *UserType) Scan(value interface{}) error {
	key := value.(string)
	for i, v := range UserTypeKey {
		if v == key {
			*s = i
		}
	}
	return nil
}

func NewUserType(value string) UserType {
	for i, v := range UserTypeKey {
		if v == value {
			return i
		}
	}
	panic("enum not found")
}

const (
	USER_PERSONAL UserType = iota + 1
	USER_CORPORATE
	OPERATOR
)

var UserTypeKey = map[UserType]string{
	USER_PERSONAL:  "USER_PERSONAL",
	USER_CORPORATE: "USER_CORPORATE",
	OPERATOR:       "OPERATOR",
}

// String for stringify UserType
func (s UserType) String() string {
	return UserTypeKey[s]
}

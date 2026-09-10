package enum

type AccountType int64

// Scan for converting byte to string for fetching/read
func (s *AccountType) Scan(value interface{}) error {
	key := value.(string)
	for i, v := range AccountTypeKey {
		if v == key {
			*s = i
		}
	}
	return nil
}

func NewAccountType(value string) AccountType {
	for i, v := range AccountTypeKey {
		if v == value {
			return i
		}
	}
	panic("enum not found")
}

const (
	PERSONAL AccountType = iota + 1
	CORPORATE
)

var AccountTypeKey = map[AccountType]string{
	PERSONAL:  "personal",
	CORPORATE: "corporate",
}

// String for stringify AccountType
func (s AccountType) String() string {
	return AccountTypeKey[s]
}

package authentication

import (
	"testing"

	"befriend/internal/model"
	"befriend/internal/model/enum"
)

func TestDecideLink(t *testing.T) {
	active := &model.User{Status: enum.ACTIVE}
	unverified := &model.User{Status: enum.UNVERIFIED}
	suspended := &model.User{Status: enum.SUSPENDED}

	tests := []struct {
		name           string
		identityLinked bool
		emailUser      *model.User
		emailVerified  bool
		want           linkAction
	}{
		{"linked identity signs in, even if an email also matches", true, active, true, linkSignIn},
		{"linked identity signs in without an email", true, nil, false, linkSignIn},
		{"verified email matching a verified account links to it", false, active, true, linkToExistingUser},
		{"verified email matching an unverified password account takes it over", false, unverified, true, linkTakeOverUnverified},
		{"verified email matching a suspended account links (sign-in then refused)", false, suspended, true, linkToExistingUser},
		{"verified email with no account creates one", false, nil, true, linkCreateUser},
		{"unverified provider email never links, even on a match", false, active, false, linkCreateUser},
		{"unverified provider email never takes over an unverified account", false, unverified, false, linkCreateUser},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := decideLink(tt.identityLinked, tt.emailUser, tt.emailVerified); got != tt.want {
				t.Fatalf("decideLink = %v; want %v", got, tt.want)
			}
		})
	}
}

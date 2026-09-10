package authentication

import (
	"befriend/internal/model"
	"befriend/internal/model/enum"
)

// linkAction is how an Apple/Google identity maps onto a befriend account.
type linkAction int

const (
	linkSignIn             linkAction = iota // identity already linked: sign that user in
	linkToExistingUser                       // verified account with the same (provider-verified) email
	linkTakeOverUnverified                   // unverified password account with that email: provider proof wins
	linkCreateUser                           // no usable match: new account
)

// decideLink applies the linking rule: an identity is attached to an existing account only when the
// provider has verified the email and it matches that account's email. Unverified provider emails never
// link, so they can't be used to take over someone else's account.
func decideLink(identityLinked bool, emailUser *model.User, providerEmailVerified bool) linkAction {
	switch {
	case identityLinked:
		return linkSignIn
	case !providerEmailVerified || emailUser == nil:
		return linkCreateUser
	case emailUser.Status == enum.UNVERIFIED:
		return linkTakeOverUnverified
	default:
		return linkToExistingUser
	}
}

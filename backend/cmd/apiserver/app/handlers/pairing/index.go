package pairing

import (
	"befriend/internal/services/authentication"
	"befriend/internal/services/pairing_code"
)

type PairingHandler struct {
	pairingCodeService    pairing_code.PairingCodeService
	authenticationService authentication.AuthenticationService
}

func NewPairingHandler(pairingCodeService pairing_code.PairingCodeService,
	authenticationService authentication.AuthenticationService) *PairingHandler {
	return &PairingHandler{
		pairingCodeService:    pairingCodeService,
		authenticationService: authenticationService,
	}
}

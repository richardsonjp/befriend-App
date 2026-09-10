package authentication

import (
	"context"

	"befriend/internal/model/enum"
	"befriend/internal/services/device"
	"befriend/internal/services/pairing_code"
	"befriend/pkg/utils/errors"
)

// ClaimPairing signs in a Mac whose pairing code an iPhone confirmed: the Mac becomes a new device of that user
// and gets its session, once. A nil response with a nil error means the code isn't confirmed yet.
func (s *authenticationService) ClaimPairing(ctx context.Context, payload pairing_code.ClaimPayload) (*AuthenticateSessionResponse, error) {
	var response *AuthenticateSessionResponse
	err := s.txRepo.Run(ctx, func(ctx context.Context) error {
		pairing, err := s.pairingCodeService.Claim(ctx, payload.Code, payload.PollSecret)
		if err != nil || pairing == nil {
			return err
		}

		owner, err := s.userService.GetUserByID(ctx, *pairing.UserID)
		if err != nil {
			if errors.Is(err, "DATA_NOT_FOUND") {
				return errors.From("PAIRING_GONE")
			}
			return err
		}
		if owner.Status != enum.ACTIVE {
			return errors.From("UNAUTHORIZED").WithDetail("Account is not active")
		}

		mac, err := s.deviceService.Create(ctx, device.CreatePayload{UserID: owner.ID, Platform: "macos", Name: pairing.DeviceName})
		if err != nil {
			return err
		}
		response, err = s.issueSession(ctx, owner.ID, mac.ID)
		return err
	})
	if err != nil {
		return nil, err
	}
	return response, nil
}

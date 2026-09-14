package user

import (
	"context"

	"befriend/internal/model"
	"befriend/pkg/clients/db"
	"befriend/pkg/utils/errors"
)

// UpdateSkin sets the account's skin (nil = the built-in one). The foreign key to skin_grant rejects a skin the
// account wasn't granted, which is reported as SKIN_NOT_FOUND.
func (s *userService) UpdateSkin(ctx context.Context, id string, skinID *string) error {
	_, err := s.userRepo.Update(ctx, model.User{ID: id, SkinID: skinID}, "skin_id")
	if db.IsForeignKeyViolation(err) {
		return errors.From("SKIN_NOT_FOUND")
	}
	return err
}

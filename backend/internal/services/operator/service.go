package operator

import (
	"context"
	"befriend/internal/model"
)

func (s *operatorService) GetOperatorByEmail(ctx context.Context, email string) (*model.Operator, error) {
	return s.operatorRepo.GetByEmail(ctx, email)
}

package personality_version

import (
	"context"

	"befriend/internal/model"
	"befriend/internal/model/enum"
)

// CreateInitial queues version 1 for generation; the pipeline picks up pending rows.
func (s *personalityVersionService) CreateInitial(ctx context.Context, friendID string) (*model.PersonalityVersion, error) {
	return s.personalityVersionRepo.Create(ctx, &model.PersonalityVersion{
		FriendID: friendID,
		Version:  1,
		Status:   enum.PERSONALITY_PENDING,
		Reason:   enum.REASON_ONBOARDING,
	})
}

func (s *personalityVersionService) GetLatestByFriend(ctx context.Context, friendID string) (*model.PersonalityVersion, error) {
	return s.personalityVersionRepo.GetLatestByFriend(ctx, friendID)
}

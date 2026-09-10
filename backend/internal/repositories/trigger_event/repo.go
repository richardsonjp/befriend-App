package trigger_event

import (
	"context"
	"time"

	"befriend/internal/model"

	"gorm.io/gorm/clause"
)

func (r *triggerEventRepo) ListRecent(ctx context.Context, userID string, limit int) ([]model.TriggerEvent, error) {
	var events []model.TriggerEvent
	err := r.dbdget.Get(ctx).
		Where("user_id = ?", userID).
		Order("occurred_at DESC").
		Limit(limit).
		Find(&events).Error
	return events, err
}

func (r *triggerEventRepo) DeleteOlderThan(ctx context.Context, before time.Time) (int64, error) {
	q := r.dbdget.Get(ctx).Where("occurred_at < ?", before).Delete(&model.TriggerEvent{})
	return q.RowsAffected, q.Error
}

func (r *triggerEventRepo) InsertNew(ctx context.Context, events []model.TriggerEvent) (int64, error) {
	if len(events) == 0 {
		return 0, nil
	}
	q := r.dbdget.Get(ctx).
		Clauses(clause.OnConflict{Columns: []clause.Column{{Name: "user_id"}, {Name: "client_event_id"}}, DoNothing: true}).
		Create(&events)
	return q.RowsAffected, q.Error
}

func (r *triggerEventRepo) DeleteByUser(ctx context.Context, userID string) error {
	return r.dbdget.Get(ctx).Where("user_id = ?", userID).Delete(&model.TriggerEvent{}).Error
}

func (r *triggerEventRepo) DeleteByApps(ctx context.Context, userID string, lowerAppNames []string) error {
	if len(lowerAppNames) == 0 {
		return nil
	}
	return r.dbdget.Get(ctx).
		Where("user_id = ? AND lower(app_name) IN ?", userID, lowerAppNames).
		Delete(&model.TriggerEvent{}).Error
}

package operator_audit_log

import (
	"context"
	"go-skeleton/internal/model"
)

func (r *operatorAuditLogRepo) Create(ctx context.Context, m *model.OperatorAuditLog) error {
	if err := r.dbdget.Get(ctx).Create(m).Error; err != nil {
		return err
	}
	return nil
}

func (r *operatorAuditLogRepo) Update(ctx context.Context, m model.OperatorAuditLog, updatedFields ...string) (int64, error) {
	query := r.dbdget.Get(ctx).
		Model(&m).
		Where("id = ?", m.ID)

	if len(updatedFields) > 0 {
		updatedFields = append(updatedFields, "updated_at")
		query = query.Select(updatedFields)
	}

	query.Updates(m)

	if query.Error != nil {
		return 0, query.Error
	}

	return query.RowsAffected, nil
}

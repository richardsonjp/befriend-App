package role

import (
	"context"
	"befriend/internal/model"
	"befriend/pkg/utils/errors"
	"math"

	"gorm.io/gorm"
)

func (r *roleRepo) Create(ctx context.Context, m *model.Role) (*model.Role, error) {
	if err := r.dbdget.Get(ctx).Create(m).Error; err != nil {
		return nil, err
	}
	return m, nil
}

func (r *roleRepo) Update(ctx context.Context, m model.Role, updatedFields ...string) (int64, error) {
	query := r.dbdget.Get(ctx).
		Model(&m).
		Where("id = ? AND account_id = ?", m.ID, m.AccountID)

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

func (r *roleRepo) GetByID(ctx context.Context, id string) (*model.Role, error) {
	var role model.Role

	db := r.dbdget.Get(ctx)

	err := db.Where("id = ?", id).
		First(&role).Error

	if err != nil {
		if err == gorm.ErrRecordNotFound {
			return nil, errors.From("DATA_NOT_FOUND")
		}
		return nil, err
	}

	return &role, nil
}

func (r *roleRepo) GetListRole(ctx context.Context, accountID string, pagination model.Pagination) ([]model.Role, *model.Pagination, error) {
	var roleList []model.Role

	db := r.dbdget.Get(ctx).Model(&model.Role{}).
		Where("account_id = ?", accountID)

	// Count
	if err := db.Count(&pagination.TotalRows).Error; err != nil {
		return nil, nil, err
	}

	// Pagination
	err := db.
		Scopes(model.NewPaginate(pagination.GetLimit(), pagination.GetPage()).PaginatedResult).
		Order("role." + pagination.GetSort()).
		Find(&roleList).Error

	if err != nil {
		return nil, nil, err
	}

	// Total pages
	pagination.TotalPages = int(math.Ceil(float64(pagination.TotalRows) / float64(pagination.Limit)))

	return roleList, &pagination, nil
}

func (r *roleRepo) GetSystemRole(ctx context.Context, accountID string) (*model.Role, error) {
	var role model.Role

	db := r.dbdget.Get(ctx)

	err := db.Where("account_id = ? AND is_system_role = true", accountID).
		First(&role).Error

	if err != nil {
		if err == gorm.ErrRecordNotFound {
			return nil, errors.From("DATA_NOT_FOUND")
		}
		return nil, err
	}

	return &role, nil
}

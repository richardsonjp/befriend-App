package user

import (
	"context"
	"befriend/internal/model"
	"befriend/pkg/utils/errors"
	"math"
	"strings"

	"gorm.io/gorm"
)

func (r *userRepo) Create(ctx context.Context, m *model.User) (*model.User, error) {
	if err := r.dbdget.Get(ctx).Create(m).Error; err != nil {
		return nil, err
	}
	return m, nil
}

func (r *userRepo) Update(ctx context.Context, m model.User, updatedFields ...string) (int64, error) {
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

func (r *userRepo) GetByID(ctx context.Context, id uint) (*model.User, error) {
	user := &model.User{}
	q := r.dbdget.Get(ctx).Where("id = ?", id).First(user)
	if q.Error != nil {
		if q.Error == gorm.ErrRecordNotFound {
			return nil, errors.From("DATA_NOT_FOUND")
		}
		return nil, q.Error
	}
	return user, nil
}

func (r *userRepo) GetByEmail(ctx context.Context, email string) (*model.User, error) {
	user := &model.User{}
	q := r.dbdget.Get(ctx).Where("email = ?", email).First(user)
	if q.Error != nil {
		if q.Error == gorm.ErrRecordNotFound {
			return nil, errors.From("DATA_NOT_FOUND")
		}
		return nil, q.Error
	}
	return user, nil
}

func (r *userRepo) GetListUser(ctx context.Context, pagination model.Pagination, filter map[string]string) ([]*UserList, *model.Pagination, error) {
	var users []*UserList
	query := r.dbdget.Get(ctx).Model(&model.User{})

	// Search
	if search := strings.TrimSpace(filter["search"]); search != "" {
		searchValue := "%" + search + "%"
		searchCondition := `(
			"user".name LIKE ?
			OR "user".email LIKE ?
			OR "user".phone LIKE ?
		)`
		query = query.Where(searchCondition, searchValue, searchValue, searchValue)
	}

	// Status filter
	if status := filter["status"]; status != "" {
		query = query.Where(`"user".status = ?`, status)
	}

	// Count total rows
	query.Count(&pagination.TotalRows)

	// Fetch paginated result with join
	err := query.Joins(`JOIN role ON role.id = "user".role_id`).
		Select([]string{
			`"user".id as id`,
			`"user".name as name`,
			`"user".email as email`,
			`"user".phone as phone`,
			"role.name as role_name",
			`"user".status as status`,
			`"user".last_login_at as last_login_at`,
			`"user".created_at as created_at`,
			`"user".updated_at as updated_at`,
		}).
		Scopes(model.NewPaginate(pagination.GetLimit(), pagination.GetPage()).PaginatedResult).
		Order(pagination.GetSort()).
		Find(&users).Error

	if err != nil {
		return nil, nil, err
	}

	pagination.TotalPages = int(math.Ceil(float64(pagination.TotalRows) / float64(pagination.Limit)))
	return users, &pagination, nil
}

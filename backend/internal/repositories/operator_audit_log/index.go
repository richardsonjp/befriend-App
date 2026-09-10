package operator_audit_log

import (
	"context"
	"go-skeleton/internal/model"
	"go-skeleton/pkg/clients/db"
)

type OperatorAuditLogRepo interface {
	Create(ctx context.Context, m *model.OperatorAuditLog) error
	Update(ctx context.Context, m model.OperatorAuditLog, updatedFields ...string) (int64, error)
}

type operatorAuditLogRepo struct {
	dbdget db.DBGormDelegate
}

func NewOperatorAuditLogRepo(dbdget db.DBGormDelegate) OperatorAuditLogRepo {
	return &operatorAuditLogRepo{
		dbdget: dbdget,
	}
}

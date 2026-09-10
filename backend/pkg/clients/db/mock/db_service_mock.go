package mock

import (
	"context"

	"github.com/DATA-DOG/go-sqlmock"
	"gorm.io/gorm"
)

type mockDBDelegate struct {
	dbGorm *gorm.DB
	mock   sqlmock.Sqlmock
}

func (m *mockDBDelegate) Init()                            {}
func (m *mockDBDelegate) InitNoUse()                       {}
func (m *mockDBDelegate) Get(ctx context.Context) *gorm.DB { return m.dbGorm }
func (m *mockDBDelegate) GetMock() sqlmock.Sqlmock         { return m.mock }
func (m *mockDBDelegate) BeginTx() *gorm.DB                { return m.dbGorm.Begin() }
func (m *mockDBDelegate) Rollback(tx *gorm.DB)             { tx.Rollback() }
func (m *mockDBDelegate) Commit(tx *gorm.DB) error         { return tx.Commit().Error }

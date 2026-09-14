package db

import (
	"errors"

	"github.com/jackc/pgx/v5/pgconn"
)

const (
	pgUniqueViolation     = "23505"
	pgForeignKeyViolation = "23503"
)

// IsUniqueViolation reports whether err is Postgres rejecting a duplicate on a unique constraint.
func IsUniqueViolation(err error) bool {
	return hasCode(err, pgUniqueViolation)
}

// IsForeignKeyViolation reports whether err is Postgres rejecting a row whose foreign key matches nothing.
func IsForeignKeyViolation(err error) bool {
	return hasCode(err, pgForeignKeyViolation)
}

func hasCode(err error, code string) bool {
	var pgErr *pgconn.PgError
	return errors.As(err, &pgErr) && pgErr.Code == code
}

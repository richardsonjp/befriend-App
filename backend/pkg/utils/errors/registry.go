package errors

import "net/http"

var Registry = map[string]AppError{
	// return 400 for general service error
	"BAD_REQUEST": {Code: "BAD_REQUEST", Status: http.StatusBadRequest, Message: "Bad request"},

	// return 401 for authentication error
	"UNAUTHORIZED": {Code: "UNAUTHORIZED", Status: http.StatusUnauthorized, Message: "Unauthorized"},

	// return 403 for authorization error
	"FORBIDDEN": {Code: "FORBIDDEN", Status: http.StatusForbidden, Message: "Forbidden request"},

	// return 422 for validation error
	"VALIDATION_FAILED": {Code: "VALIDATION_FAILED", Status: http.StatusUnprocessableEntity, Message: "Validation failed"},

	// return 500 for internal server error (internal server dependency: DB, pipeline, queue, etc)
	"INTERNAL_SERVER_ERROR": {Code: "INTERNAL_SERVER_ERROR", Status: http.StatusInternalServerError, Message: "Internal server error"},

	// domain specific error
	"DATA_NOT_FOUND": {Code: "DATA_NOT_FOUND", Status: http.StatusNotFound, Message: "Data not found"},

	// services specific error:
	// # authentication
	"ACCOUNT":           {Code: "ACCOUNT", Status: http.StatusBadRequest, Message: "Account bad request"},
	"ACCOUNT_MEMBER":    {Code: "ACCOUNT_MEMBER", Status: http.StatusBadRequest, Message: "Account Member bad request"},
	"USER":              {Code: "USER", Status: http.StatusBadRequest, Message: "User bad request"},
	"ROLE":              {Code: "ROLE", Status: http.StatusBadRequest, Message: "Role bad request"},
	"VERIFICATION_CODE": {Code: "VERIFICATION_CODE", Status: http.StatusBadRequest, Message: "Verification Code bad request"},
}

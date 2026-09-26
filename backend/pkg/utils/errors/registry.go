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
	"DATA_CONFLICT":  {Code: "DATA_CONFLICT", Status: http.StatusConflict, Message: "Data already exists"},

	// return 429 when a client is rate limited or must wait before retrying
	"TOO_MANY_REQUESTS": {Code: "TOO_MANY_REQUESTS", Status: http.StatusTooManyRequests, Message: "Too many requests"},

	// services specific error:
	// # authentication
	"USER":              {Code: "USER", Status: http.StatusBadRequest, Message: "User bad request"},
	"VERIFICATION_CODE": {Code: "VERIFICATION_CODE", Status: http.StatusBadRequest, Message: "Verification Code bad request"},
	// # pairing: the code expired, was already used, or doesn't match
	"PAIRING_GONE": {Code: "PAIRING_GONE", Status: http.StatusGone, Message: "Pairing code expired"},
	// # skins: not published, or not granted to this account (the two look the same)
	"SKIN_NOT_FOUND":       {Code: "SKIN_NOT_FOUND", Status: http.StatusNotFound, Message: "Skin not found"},
	"NOT_AN_ARTIST":        {Code: "NOT_AN_ARTIST", Status: http.StatusForbidden, Message: "Only invited artists can submit skins"},
	"SKIN_TAKEN":           {Code: "SKIN_TAKEN", Status: http.StatusConflict, Message: "Another artist's skin already uses this id"},
	"SKIN_INVALID":         {Code: "SKIN_INVALID", Status: http.StatusUnprocessableEntity, Message: "The skin doesn't follow the format"},
	"TOO_MANY_SUBMISSIONS": {Code: "TOO_MANY_SUBMISSIONS", Status: http.StatusTooManyRequests, Message: "Wait for your submissions to be reviewed first"},
	"SUBMISSION_NOT_FOUND": {Code: "SUBMISSION_NOT_FOUND", Status: http.StatusNotFound, Message: "Submission not found"},
}

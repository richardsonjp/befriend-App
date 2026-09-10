package errors

import "fmt"

type AppError struct {
	Code    string   `json:"code"`    // ex: USER_NOT_FOUND
	Message string   `json:"message"` // human readable
	Status  int      `json:"status"`  // http code
	Details []string `json:"details,omitempty"`
}

func (e *AppError) Error() string {
	return fmt.Sprintf("%s - %s", e.Code, e.Message)
}

func New(code string, status int, message string) *AppError {
	return &AppError{
		Code:    code,
		Status:  status,
		Message: message,
	}
}

func From(code string) *AppError {
	if e, ok := Registry[code]; ok {
		return &AppError{
			Code:    e.Code,
			Status:  e.Status,
			Message: e.Message,
		}
	}

	return &AppError{
		Code:    "INTERNAL_SERVER_ERROR",
		Status:  500,
		Message: "Unhandled error",
	}
}

func (e *AppError) WithMessage(msg string) *AppError {
	e.Message = msg
	return e
}

func (e *AppError) WithStatus(status int) *AppError {
	e.Status = status
	return e
}

func (e *AppError) WithDetail(detail string) *AppError {
	e.Details = append(e.Details, detail)
	return e
}

func (e *AppError) WithDetails(details []string) *AppError {
	e.Details = append(e.Details, details...)
	return e
}

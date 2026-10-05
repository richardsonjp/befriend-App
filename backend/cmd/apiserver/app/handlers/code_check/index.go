package code_check

import (
	serviceCodeCheck "befriend/internal/services/code_check"
)

type CodeCheckHandler struct {
	codeCheckService serviceCodeCheck.CodeCheckService
}

func NewCodeCheckHandler(codeCheckService serviceCodeCheck.CodeCheckService) *CodeCheckHandler {
	return &CodeCheckHandler{codeCheckService: codeCheckService}
}

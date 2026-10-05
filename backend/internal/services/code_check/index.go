package code_check

import (
	"context"
	"sync"
	"time"

	"befriend/pkg/clients/godbolt"
)

// CodeCheckService compiles (and runs once) model-written code on Compiler Explorer for the app (M40). Nothing
// runs on befriend's own servers.
type CodeCheckService interface {
	Check(ctx context.Context, payload CheckPayload) (*CheckResponse, error)
}

// compilerAPI is the part of the godbolt client the service uses (a fake in tests).
type compilerAPI interface {
	Compilers(ctx context.Context, language string) ([]godbolt.Compiler, error)
	Compile(ctx context.Context, compilerID, language, source string, execute bool) (*godbolt.Result, error)
}

type codeCheckService struct {
	godbolt compilerAPI
	now     func() time.Time

	mu        sync.Mutex
	compilers map[string]pickedCompiler // by godbolt language id
}

type pickedCompiler struct {
	compiler godbolt.Compiler
	at       time.Time
}

func NewCodeCheckService(client compilerAPI) CodeCheckService {
	return &codeCheckService{godbolt: client, now: time.Now, compilers: map[string]pickedCompiler{}}
}

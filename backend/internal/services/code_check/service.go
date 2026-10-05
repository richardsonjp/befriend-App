package code_check

import (
	"context"
	"strings"
	"time"

	"befriend/pkg/clients/godbolt"
	"befriend/pkg/utils/errors"
)

// A language: its Compiler Explorer id and the kind of compiler to use there (the newest released one is picked).
// JavaScript and TypeScript are left out: godbolt can't run JS, and its TypeScript is a pre-release JIT.
type language struct{ godbolt, compilerType string }

var languages = map[string]language{
	"go":     {"go", "golang"},
	"python": {"python", "python"},
	"swift":  {"swift", "swift"},
	"rust":   {"rust", "rust"},
	"c":      {"c", "clang"},
	"cpp":    {"c++", "clang"},
	"java":   {"java", "java"},
	"kotlin": {"kotlin", "kotlin"},
	"ruby":   {"ruby", "ruby"},
	"csharp": {"csharp", "dotnetcoreclr"},
}

var aliases = map[string]string{
	"golang": "go", "py": "python", "python3": "python", "rs": "rust", "c++": "cpp", "cxx": "cpp", "cc": "cpp",
	"kt": "kotlin", "rb": "ruby", "c#": "csharp", "cs": "csharp",
}

const (
	// compilerTTL: how long a picked compiler is reused before the list is asked again (new versions appear).
	compilerTTL = 24 * time.Hour
	// maxOutput caps each text field sent back: enough for errors and a program's output, not a flood.
	maxOutput = 8 << 10
)

func normalized(name string) (string, language, bool) {
	key := strings.ToLower(strings.TrimSpace(name))
	if alias, ok := aliases[key]; ok {
		key = alias
	}
	lang, ok := languages[key]
	return key, lang, ok
}

func (s *codeCheckService) Check(ctx context.Context, payload CheckPayload) (*CheckResponse, error) {
	key, lang, ok := normalized(payload.Language)
	if !ok {
		return nil, errors.From("CODE_LANGUAGE_UNSUPPORTED").WithDetail(payload.Language)
	}
	compiler, err := s.compiler(ctx, lang)
	if err != nil {
		return nil, err
	}
	result, err := s.godbolt.Compile(ctx, compiler.ID, lang.godbolt, payload.Source, payload.Run)
	if err != nil {
		return nil, errors.From("CODE_CHECK_FAILED").WithDetail(err.Error())
	}
	return response(key, compiler, result), nil
}

// response says whether the code works: built and, when run, exited cleanly. A script's mistakes (Python's syntax
// errors among them) only show when it runs, so its stderr counts as the errors then.
func response(key string, compiler godbolt.Compiler, result *godbolt.Result) *CheckResponse {
	out := &CheckResponse{
		Language: key, Compiler: compiler.Name, Compiled: result.Built, Ran: result.Ran, ExitCode: result.ExitCode,
		Stdout: capped(result.Stdout), Stderr: capped(result.Stderr), TimedOut: result.TimedOut,
	}
	switch {
	case !result.Built:
		out.Errors = capped(result.BuildLog)
	case result.Ran && result.ExitCode != 0 && strings.TrimSpace(result.Stdout) == "":
		out.Compiled = false
		out.Errors = capped(result.Stderr)
	}
	return out
}

func (s *codeCheckService) compiler(ctx context.Context, lang language) (godbolt.Compiler, error) {
	s.mu.Lock()
	cached, ok := s.compilers[lang.godbolt]
	s.mu.Unlock()
	if ok && s.now().Sub(cached.at) < compilerTTL {
		return cached.compiler, nil
	}
	list, err := s.godbolt.Compilers(ctx, lang.godbolt)
	if err != nil {
		return godbolt.Compiler{}, errors.From("CODE_CHECK_FAILED").WithDetail(err.Error())
	}
	compiler, ok := godbolt.Pick(list, lang.compilerType)
	if !ok {
		return godbolt.Compiler{}, errors.From("CODE_LANGUAGE_UNSUPPORTED").WithDetail(lang.godbolt)
	}
	s.mu.Lock()
	s.compilers[lang.godbolt] = pickedCompiler{compiler: compiler, at: s.now()}
	s.mu.Unlock()
	return compiler, nil
}

func capped(text string) string {
	if len(text) <= maxOutput {
		return text
	}
	return text[:maxOutput] + "\n…(cut)"
}

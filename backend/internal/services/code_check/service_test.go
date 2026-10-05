package code_check

import (
	"context"
	"strings"
	"testing"
	"time"

	"befriend/pkg/clients/godbolt"
	"befriend/pkg/utils/errors"
)

type fakeGodbolt struct {
	listed   int
	compiled []string // compiler ids
	result   *godbolt.Result
}

func (f *fakeGodbolt) Compilers(_ context.Context, language string) ([]godbolt.Compiler, error) {
	f.listed++
	return []godbolt.Compiler{
		{ID: language + "-old", Name: "old", Semver: "1.2.0", InstructionSet: "amd64", CompilerType: map[string]string{"go": "golang", "python": "python"}[language], SupportsExecute: true},
		{ID: language + "-new", Name: "new", Semver: "1.10.0", InstructionSet: "amd64", CompilerType: map[string]string{"go": "golang", "python": "python"}[language], SupportsExecute: true},
	}, nil
}

func (f *fakeGodbolt) Compile(_ context.Context, compilerID, _, _ string, _ bool) (*godbolt.Result, error) {
	f.compiled = append(f.compiled, compilerID)
	return f.result, nil
}

func TestCheckPicksTheCompilerOnceAndAcceptsAliases(t *testing.T) {
	fake := &fakeGodbolt{result: &godbolt.Result{Built: true, Ran: true, Stdout: "hi"}}
	service := NewCodeCheckService(fake).(*codeCheckService)
	for _, name := range []string{"go", "Golang", " GO "} {
		got, err := service.Check(t.Context(), CheckPayload{Language: name, Source: "package main", Run: true})
		if err != nil || !got.Compiled || got.Stdout != "hi" || got.Language != "go" || got.Compiler != "new" {
			t.Fatalf("%q: %+v, %v", name, got, err)
		}
	}
	if fake.listed != 1 || strings.Join(fake.compiled, ",") != "go-new,go-new,go-new" {
		t.Fatalf("listed %d times, compiled with %v", fake.listed, fake.compiled)
	}
	service.now = func() time.Time { return time.Now().Add(25 * time.Hour) }
	_, _ = service.Check(t.Context(), CheckPayload{Language: "go", Source: "x"})
	if fake.listed != 2 {
		t.Fatal("after a day the list is asked again")
	}
}

func TestUnsupportedLanguagesAreRefused(t *testing.T) {
	service := NewCodeCheckService(&fakeGodbolt{})
	_, err := service.Check(t.Context(), CheckPayload{Language: "javascript", Source: "x"})
	if !errors.Is(err, "CODE_LANGUAGE_UNSUPPORTED") {
		t.Fatalf("err = %v", err)
	}
}

func TestAScriptThatFailsWhenRunHasNotCompiled(t *testing.T) {
	compiler := godbolt.Compiler{Name: "Python 3.13"}
	syntax := response("python", compiler, &godbolt.Result{Built: true, Ran: true, ExitCode: 1, Stderr: "SyntaxError: '(' was never closed"})
	if syntax.Compiled || !strings.Contains(syntax.Errors, "SyntaxError") {
		t.Fatalf("syntax error: %+v", syntax)
	}
	exits := response("python", compiler, &godbolt.Result{Built: true, Ran: true, ExitCode: 3, Stdout: "hi 3"})
	if !exits.Compiled || exits.Errors != "" || exits.ExitCode != 3 {
		t.Fatalf("a program that prints and exits 3 ran fine: %+v", exits)
	}
	build := response("go", compiler, &godbolt.Result{Built: false, BuildLog: "./example.go:5:2: undefined: sort"})
	if build.Compiled || build.Errors != "./example.go:5:2: undefined: sort" {
		t.Fatalf("build error: %+v", build)
	}
	if long := capped(strings.Repeat("x", maxOutput+10)); !strings.HasSuffix(long, "…(cut)") || len(long) > maxOutput+20 {
		t.Fatal("output is capped")
	}
}

package godbolt

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestPickTakesTheNewestReleasedCompilerThatRuns(t *testing.T) {
	compilers := []Compiler{
		{ID: "gl194", Semver: "1.9.4", InstructionSet: "amd64", CompilerType: "golang", SupportsExecute: true},
		{ID: "gl1260", Semver: "1.26.0", InstructionSet: "amd64", CompilerType: "golang", SupportsExecute: true},
		{ID: "gltip", Semver: "tip", InstructionSet: "amd64", CompilerType: "golang", SupportsExecute: true},
		{ID: "arm_gl1270", Semver: "1.27.0", InstructionSet: "arm", CompilerType: "golang", SupportsExecute: true},
		{ID: "tinygo", Semver: "0.40.0", InstructionSet: "amd64", CompilerType: "tinygo", SupportsExecute: true},
		{ID: "gl1300", Semver: "1.30.0", InstructionSet: "amd64", CompilerType: "golang", SupportsExecute: false},
	}
	got, ok := Pick(compilers, "golang")
	if !ok || got.ID != "gl1260" {
		t.Fatalf("Pick = %+v, %v; want gl1260 (numbered, x86-64, runs; 1.26 > 1.9)", got, ok)
	}
	if _, ok := Pick(compilers, "rust"); ok {
		t.Fatal("no rust compiler listed, yet one was picked")
	}
	java := []Compiler{{ID: "java2101", Semver: "21.0.1", InstructionSet: "java", CompilerType: "java", SupportsExecute: true}}
	if got, ok := Pick(java, "java"); !ok || got.ID != "java2101" {
		t.Fatal("a language without x86-64 builds keeps its own")
	}
}

func TestCompileRunsAndSplitsBuildFromProgram(t *testing.T) {
	var sent map[string]interface{}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/compiler/gl1260/compile" || r.Header.Get("Accept") != "application/json" {
			t.Errorf("unexpected request %s accept=%q", r.URL.Path, r.Header.Get("Accept"))
		}
		_ = json.NewDecoder(r.Body).Decode(&sent)
		_, _ = w.Write([]byte(`{"code":0,"didExecute":true,"timedOut":false,"stdout":[{"text":"hi 3"}],"stderr":[],
			"buildResult":{"code":0,"stdout":[],"stderr":[]}}`))
	}))
	defer srv.Close()

	result, err := New(Config{BaseURL: srv.URL}).Compile(t.Context(), "gl1260", "go", "package main", true)
	if err != nil {
		t.Fatalf("Compile: %v", err)
	}
	if !result.Built || !result.Ran || result.ExitCode != 0 || result.Stdout != "hi 3" {
		t.Fatalf("result = %+v", result)
	}
	filters := sent["options"].(map[string]interface{})["filters"].(map[string]interface{})
	if sent["source"] != "package main" || filters["execute"] != true {
		t.Fatalf("sent = %v", sent)
	}
}

func TestCompileReportsBuildErrorsWithoutRunning(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"code":-1,"didExecute":false,"stdout":[],"stderr":[],
			"buildResult":{"code":1,"stdout":[],"stderr":[{"text":"# command-line-arguments"},{"text":"./example.go:5:2: \"math\" imported and not used"}]}}`))
	}))
	defer srv.Close()

	result, err := New(Config{BaseURL: srv.URL}).Compile(t.Context(), "gl1260", "go", "x", true)
	if err != nil {
		t.Fatalf("Compile: %v", err)
	}
	if result.Built || result.Ran || !strings.Contains(result.BuildLog, `example.go:5:2: "math" imported and not used`) {
		t.Fatalf("result = %+v", result)
	}
}

func TestErrorsSayWhatWentWrong(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusTooManyRequests)
		_, _ = w.Write([]byte("slow down"))
	}))
	defer srv.Close()
	_, err := New(Config{BaseURL: srv.URL}).Compilers(t.Context(), "go")
	if err == nil || !strings.Contains(err.Error(), "status 429") {
		t.Fatalf("err = %v", err)
	}
}

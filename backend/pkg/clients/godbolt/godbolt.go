// Package godbolt calls Compiler Explorer (godbolt.org): it compiles code with real compilers and runs it in its own
// sandbox, so the app can check model-written code without befriend shipping or running any toolchain.
package godbolt

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"time"
)

const (
	defaultBaseURL   = "https://godbolt.org"
	defaultTimeout   = 60 * time.Second // a queued compile and run on the public site
	maxResponseBytes = 4 << 20
)

type Config struct {
	BaseURL string // defaults to godbolt.org; changed only for tests
	Timeout time.Duration
}

type Client struct {
	cfg  Config
	http *http.Client
}

func New(cfg Config) *Client {
	if cfg.BaseURL == "" {
		cfg.BaseURL = defaultBaseURL
	}
	if cfg.Timeout == 0 {
		cfg.Timeout = defaultTimeout
	}
	cfg.BaseURL = strings.TrimRight(cfg.BaseURL, "/")
	return &Client{cfg: cfg, http: &http.Client{Timeout: cfg.Timeout}}
}

// Compiler is one entry of Compiler Explorer's list for a language.
type Compiler struct {
	ID              string `json:"id"`
	Name            string `json:"name"`
	Semver          string `json:"semver"`
	InstructionSet  string `json:"instructionSet"`
	CompilerType    string `json:"compilerType"`
	SupportsExecute bool   `json:"supportsExecute"`
}

// Result is a compile and, when asked and the build worked, one run.
type Result struct {
	Built     bool
	BuildLog  string // the compiler's messages, "file:line:col: …" lines
	Ran       bool
	ExitCode  int
	Stdout    string
	Stderr    string
	TimedOut  bool
	Truncated bool
}

// Compilers lists a language's compilers (godbolt language ids: "go", "python", "c++"…).
func (c *Client) Compilers(ctx context.Context, language string) ([]Compiler, error) {
	endpoint := fmt.Sprintf("%s/api/compilers/%s?fields=id,name,semver,instructionSet,compilerType,supportsExecute",
		c.cfg.BaseURL, url.PathEscape(language))
	var compilers []Compiler
	if err := c.do(ctx, http.MethodGet, endpoint, nil, &compilers); err != nil {
		return nil, err
	}
	return compilers, nil
}

// Compile builds source with the compiler and, with execute, runs it once in godbolt's sandbox.
func (c *Client) Compile(ctx context.Context, compilerID, language, source string, execute bool) (*Result, error) {
	body := map[string]interface{}{
		"source": source,
		"lang":   language,
		"options": map[string]interface{}{
			"userArguments":   "",
			"compilerOptions": map[string]interface{}{"executorRequest": execute},
			"filters":         map[string]interface{}{"execute": execute},
		},
	}
	var reply struct {
		Code        int  `json:"code"`
		DidExecute  bool `json:"didExecute"`
		TimedOut    bool `json:"timedOut"`
		Truncated   bool `json:"truncated"`
		Stdout      []line
		Stderr      []line
		BuildResult *struct {
			Code   int    `json:"code"`
			Stdout []line `json:"stdout"`
			Stderr []line `json:"stderr"`
		} `json:"buildResult"`
	}
	endpoint := fmt.Sprintf("%s/api/compiler/%s/compile", c.cfg.BaseURL, url.PathEscape(compilerID))
	if err := c.do(ctx, http.MethodPost, endpoint, body, &reply); err != nil {
		return nil, err
	}
	// Executed: the build's messages are in buildResult and the program's in stdout/stderr. Compile only: the
	// compiler's messages are in stdout/stderr.
	result := &Result{TimedOut: reply.TimedOut, Truncated: reply.Truncated}
	if reply.BuildResult != nil {
		result.Built = reply.BuildResult.Code == 0
		result.BuildLog = joined(append(reply.BuildResult.Stderr, reply.BuildResult.Stdout...))
	} else {
		result.Built = reply.Code == 0
		result.BuildLog = joined(append(reply.Stderr, reply.Stdout...))
	}
	if reply.DidExecute {
		result.Ran = true
		result.ExitCode = reply.Code
		result.Stdout = joined(reply.Stdout)
		result.Stderr = joined(reply.Stderr)
	}
	return result, nil
}

type line struct {
	Text string `json:"text"`
}

func joined(lines []line) string {
	texts := make([]string, 0, len(lines))
	for _, l := range lines {
		texts = append(texts, l.Text)
	}
	return strings.Join(texts, "\n")
}

var numericVersion = regexp.MustCompile(`^\d+(\.\d+)*$`)

// Pick is the newest released compiler of compilerType that can run code: numbered versions only (not "trunk" or
// "nightly"), x86-64 where the language has it. Sorting ids as text picked Go 1.9.4 as the newest.
func Pick(compilers []Compiler, compilerType string) (Compiler, bool) {
	var candidates []Compiler
	hasAMD64 := false
	for _, c := range compilers {
		if c.CompilerType == compilerType && c.SupportsExecute && numericVersion.MatchString(c.Semver) {
			candidates = append(candidates, c)
			hasAMD64 = hasAMD64 || c.InstructionSet == "amd64"
		}
	}
	var best Compiler
	found := false
	for _, c := range candidates {
		if hasAMD64 && c.InstructionSet != "amd64" {
			continue
		}
		if !found || newer(c.Semver, best.Semver) {
			best, found = c, true
		}
	}
	return best, found
}

// newer reports whether version a ("1.26.0") is above b, number by number.
func newer(a, b string) bool {
	as, bs := strings.Split(a, "."), strings.Split(b, ".")
	for i := 0; i < len(as) || i < len(bs); i++ {
		x, y := 0, 0
		if i < len(as) {
			x, _ = strconv.Atoi(as[i])
		}
		if i < len(bs) {
			y, _ = strconv.Atoi(bs[i])
		}
		if x != y {
			return x > y
		}
	}
	return false
}

func (c *Client) do(ctx context.Context, method, endpoint string, body interface{}, out interface{}) error {
	var reader io.Reader
	if body != nil {
		data, err := json.Marshal(body)
		if err != nil {
			return err
		}
		reader = bytes.NewReader(data)
	}
	req, err := http.NewRequestWithContext(ctx, method, endpoint, reader)
	if err != nil {
		return err
	}
	req.Header.Set("Accept", "application/json")
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := c.http.Do(req)
	if err != nil {
		return fmt.Errorf("godbolt: %w", err)
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, maxResponseBytes))
	if err != nil {
		return fmt.Errorf("godbolt: reading the reply: %w", err)
	}
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("godbolt: status %d: %s", resp.StatusCode, strings.TrimSpace(string(data[:min(len(data), 300)])))
	}
	if err := json.Unmarshal(data, out); err != nil {
		return fmt.Errorf("godbolt: unreadable reply: %w", err)
	}
	return nil
}

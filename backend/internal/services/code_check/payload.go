package code_check

type CheckPayload struct {
	UserID string `json:"-"`
	// The code's language as the app names it: "go", "python", "swift", "c++"… (aliases like "golang" or "py" work).
	Language string `json:"language" validate:"required,max=20"`
	Source   string `json:"source" validate:"required,max=65536"`
	// Run it once in Compiler Explorer's sandbox when it compiles.
	Run bool `json:"run"`
}

type CheckResponse struct {
	Language string `json:"language"`
	Compiler string `json:"compiler"`
	// Compiled: the compiler accepted it. Errors: what the compiler (or, for scripts, the run) said when it didn't.
	Compiled bool   `json:"compiled"`
	Errors   string `json:"errors"`
	Ran      bool   `json:"ran"`
	ExitCode int    `json:"exit_code"`
	Stdout   string `json:"stdout"`
	Stderr   string `json:"stderr"`
	TimedOut bool   `json:"timed_out"`
}

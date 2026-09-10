package api

type Base struct {
	Message string      `json:"message,omitempty"`
	Data    interface{} `json:"data,omitempty"`
}

type Error struct {
	Message string      `json:"message"`
	Details interface{} `json:"details,omitempty"`
}

package http

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/gofiber/fiber/v3/client"
)

const (
	defaultTimeout    = 30 * time.Second
	defaultMaxRetries = 3
	defaultRetryDelay = 1 * time.Second
)

// Client wraps Fiber v3 client with production-ready features
type Client struct {
	client      *client.Client
	retryConfig *RetryConfig
	logger      Logger
}

// RetryConfig defines retry behavior
type RetryConfig struct {
	MaxRetries int
	RetryDelay time.Duration
	RetryIf    func(statusCode int) bool
}

// Logger interface for structured logging
type Logger interface {
	Info(msg string, fields map[string]interface{})
	Error(msg string, fields map[string]interface{})
	Debug(msg string, fields map[string]interface{})
}

// RequestOptions contains per-request configuration
type RequestOptions struct {
	Headers     map[string]string
	QueryParams map[string]string
	PathParams  map[string]string
	Cookies     map[string]string
	Timeout     *time.Duration
	Context     context.Context
	Body        interface{}
	FormData    map[string]string
}

// Response wraps the Fiber response with useful metadata
type Response struct {
	StatusCode int
	Body       []byte
	Headers    map[string]string
	Duration   time.Duration
	rawResp    *client.Response
}

// ClientBuilder provides a fluent interface for building HTTP clients
type ClientBuilder struct {
	baseURL     string
	timeout     time.Duration
	headers     map[string]string
	queryParams map[string]string
	retryConfig *RetryConfig
	logger      Logger
	userAgent   string
	debug       bool
}

// NewClientBuilder creates a new HTTP client builder
func NewClientBuilder() *ClientBuilder {
	return &ClientBuilder{
		timeout:     defaultTimeout,
		headers:     make(map[string]string),
		queryParams: make(map[string]string),
		retryConfig: &RetryConfig{
			MaxRetries: defaultMaxRetries,
			RetryDelay: defaultRetryDelay,
			RetryIf:    defaultRetryCondition,
		},
	}
}

// WithBaseURL sets the base URL for all requests
func (b *ClientBuilder) WithBaseURL(url string) *ClientBuilder {
	b.baseURL = url
	return b
}

// WithTimeout sets the default request timeout
func (b *ClientBuilder) WithTimeout(timeout time.Duration) *ClientBuilder {
	b.timeout = timeout
	return b
}

// WithHeader adds a default header to all requests
func (b *ClientBuilder) WithHeader(key, value string) *ClientBuilder {
	b.headers[key] = value
	return b
}

// WithHeaders adds multiple default headers
func (b *ClientBuilder) WithHeaders(headers map[string]string) *ClientBuilder {
	for k, v := range headers {
		b.headers[k] = v
	}
	return b
}

// WithQueryParam adds a default query parameter to all requests
func (b *ClientBuilder) WithQueryParam(key, value string) *ClientBuilder {
	b.queryParams[key] = value
	return b
}

// WithQueryParams adds multiple default query parameters
func (b *ClientBuilder) WithQueryParams(params map[string]string) *ClientBuilder {
	for k, v := range params {
		b.queryParams[k] = v
	}
	return b
}

// WithRetry configures retry behavior
func (b *ClientBuilder) WithRetry(maxRetries int, delay time.Duration) *ClientBuilder {
	b.retryConfig.MaxRetries = maxRetries
	b.retryConfig.RetryDelay = delay
	return b
}

// WithRetryCondition sets custom retry condition
func (b *ClientBuilder) WithRetryCondition(fn func(statusCode int) bool) *ClientBuilder {
	b.retryConfig.RetryIf = fn
	return b
}

// WithLogger sets a custom logger
func (b *ClientBuilder) WithLogger(logger Logger) *ClientBuilder {
	b.logger = logger
	return b
}

// WithUserAgent sets the user agent
func (b *ClientBuilder) WithUserAgent(ua string) *ClientBuilder {
	b.userAgent = ua
	return b
}

// WithDebug enables debug mode
func (b *ClientBuilder) WithDebug(debug bool) *ClientBuilder {
	b.debug = debug
	return b
}

// Build creates the configured HTTP client
func (b *ClientBuilder) Build() *Client {
	c := client.New()

	// Configure client
	if b.baseURL != "" {
		c.SetBaseURL(b.baseURL)
	}

	c.SetTimeout(b.timeout)

	if len(b.headers) > 0 {
		c.SetHeaders(b.headers)
	}

	if len(b.queryParams) > 0 {
		c.SetParams(b.queryParams)
	}

	if b.userAgent != "" {
		c.SetUserAgent(b.userAgent)
	}

	if b.debug {
		c.Debug()
	}

	if b.logger != nil {
		// Note: Fiber v3 has SetLogger but requires log.CommonLogger interface
		// You may need to create an adapter if your Logger interface differs
	}

	return &Client{
		client:      c,
		retryConfig: b.retryConfig,
		logger:      b.logger,
	}
}

// Get performs a GET request
func (c *Client) Get(url string, opts *RequestOptions) (*Response, error) {
	cfg := c.buildConfig(opts)
	return c.doWithRetry(func() (*client.Response, error) {
		return c.client.Get(url, cfg)
	}, url, "GET")
}

// Post performs a POST request
func (c *Client) Post(url string, opts *RequestOptions) (*Response, error) {
	cfg := c.buildConfig(opts)
	return c.doWithRetry(func() (*client.Response, error) {
		return c.client.Post(url, cfg)
	}, url, "POST")
}

// Put performs a PUT request
func (c *Client) Put(url string, opts *RequestOptions) (*Response, error) {
	cfg := c.buildConfig(opts)
	return c.doWithRetry(func() (*client.Response, error) {
		return c.client.Put(url, cfg)
	}, url, "PUT")
}

// Patch performs a PATCH request
func (c *Client) Patch(url string, opts *RequestOptions) (*Response, error) {
	cfg := c.buildConfig(opts)
	return c.doWithRetry(func() (*client.Response, error) {
		return c.client.Patch(url, cfg)
	}, url, "PATCH")
}

// Delete performs a DELETE request
func (c *Client) Delete(url string, opts *RequestOptions) (*Response, error) {
	cfg := c.buildConfig(opts)
	return c.doWithRetry(func() (*client.Response, error) {
		return c.client.Delete(url, cfg)
	}, url, "DELETE")
}

// Head performs a HEAD request
func (c *Client) Head(url string, opts *RequestOptions) (*Response, error) {
	cfg := c.buildConfig(opts)
	return c.doWithRetry(func() (*client.Response, error) {
		return c.client.Head(url, cfg)
	}, url, "HEAD")
}

// buildConfig creates a Fiber client.Config from RequestOptions
func (c *Client) buildConfig(opts *RequestOptions) client.Config {
	cfg := client.Config{}

	if opts == nil {
		return cfg
	}

	if opts.Context != nil {
		cfg.Ctx = opts.Context
	}

	if opts.Headers != nil {
		cfg.Header = opts.Headers
	}

	if opts.QueryParams != nil {
		cfg.Param = opts.QueryParams
	}

	if opts.PathParams != nil {
		cfg.PathParam = opts.PathParams
	}

	if opts.Cookies != nil {
		cfg.Cookie = opts.Cookies
	}

	if opts.Timeout != nil {
		cfg.Timeout = *opts.Timeout
	}

	if opts.Body != nil {
		cfg.Body = opts.Body
	}

	if opts.FormData != nil {
		cfg.FormData = opts.FormData
	}

	return cfg
}

// doWithRetry executes the request with retry logic
func (c *Client) doWithRetry(fn func() (*client.Response, error), url, method string) (*Response, error) {
	startTime := time.Now()
	var lastErr error
	var resp *client.Response

	maxAttempts := 1
	if c.retryConfig != nil {
		maxAttempts = c.retryConfig.MaxRetries + 1
	}

	for attempt := 0; attempt < maxAttempts; attempt++ {
		if attempt > 0 {
			delay := c.retryConfig.RetryDelay * time.Duration(attempt)
			c.logRetry(method, url, attempt, lastErr, delay)
			time.Sleep(delay)
		}

		resp, lastErr = fn()

		if lastErr != nil {
			if attempt < maxAttempts-1 {
				continue
			}
			return nil, fmt.Errorf("request failed after %d attempts: %w", maxAttempts, lastErr)
		}

		duration := time.Since(startTime)
		response := c.buildResponse(resp, duration)

		// Log request
		c.logRequest(method, url, response.StatusCode, duration, nil)

		// Check if we should retry based on status code
		if c.retryConfig != nil && c.retryConfig.RetryIf != nil {
			if c.retryConfig.RetryIf(response.StatusCode) && attempt < maxAttempts-1 {
				lastErr = fmt.Errorf("HTTP %d", response.StatusCode)
				continue
			}
		}

		return response, nil
	}

	return nil, fmt.Errorf("max retries exceeded: %w", lastErr)
}

// buildResponse creates a Response from Fiber client response
func (c *Client) buildResponse(resp *client.Response, duration time.Duration) *Response {
	response := &Response{
		StatusCode: resp.StatusCode(),
		Body:       make([]byte, len(resp.Body())),
		Headers:    make(map[string]string),
		Duration:   duration,
		rawResp:    resp,
	}

	copy(response.Body, resp.Body())

	// Extract headers
	resp.RawResponse.Header.VisitAll(func(key, value []byte) {
		response.Headers[string(key)] = string(value)
	})

	return response
}

// JSON unmarshals the response body into the provided interface
func (r *Response) JSON(v interface{}) error {
	return json.Unmarshal(r.Body, v)
}

// String returns the response body as a string
func (r *Response) String() string {
	return string(r.Body)
}

// IsSuccess returns true if the status code is 2xx
func (r *Response) IsSuccess() bool {
	return r.StatusCode >= 200 && r.StatusCode < 300
}

// IsError returns true if the status code is 4xx or 5xx
func (r *Response) IsError() bool {
	return r.StatusCode >= 400
}

// defaultRetryCondition is the default retry logic
func defaultRetryCondition(statusCode int) bool {
	// Retry on 5xx only. A 429 means "slow down": blind retries just burn the caller's rate limit
	// (e.g. OpenRouter's per-minute cap), so callers handle 429 themselves.
	return statusCode >= 500
}

// logRequest logs the HTTP request details
func (c *Client) logRequest(method, url string, statusCode int, duration time.Duration, err error) {
	if c.logger == nil {
		return
	}

	fields := map[string]interface{}{
		"method":      method,
		"url":         url,
		"status_code": statusCode,
		"duration_ms": duration.Milliseconds(),
	}

	if err != nil {
		fields["error"] = err.Error()
		c.logger.Error("HTTP request failed", fields)
	} else {
		c.logger.Info("HTTP request completed", fields)
	}
}

// logRetry logs retry attempts
func (c *Client) logRetry(method, url string, attempt int, err error, delay time.Duration) {
	if c.logger == nil {
		return
	}

	c.logger.Debug("Retrying HTTP request", map[string]interface{}{
		"method":   method,
		"url":      url,
		"attempt":  attempt + 1,
		"error":    err.Error(),
		"delay_ms": delay.Milliseconds(),
	})
}

// GetClient returns the underlying Fiber client for advanced usage
func (c *Client) GetClient() *client.Client {
	return c.client
}

// Reset resets the client to default state
func (c *Client) Reset() {
	c.client.Reset()
}

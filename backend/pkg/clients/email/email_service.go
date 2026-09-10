package email

import (
	"crypto/tls"
	"fmt"
	"net"
	"net/smtp"
	"strings"
	"time"
)

const (
	dialTimeout = 10 * time.Second
	sendTimeout = 30 * time.Second
)

// SMTPConfig holds the configuration for the SMTP server
type SMTPConfig struct {
	Host     string
	Port     string
	Username string
	Password string
	From     string
}

// EmailSender defines the interface for sending emails
type EmailSender interface {
	SendEmail(req *EmailRequest) error
}

// SMTPSender implements EmailSender using net/smtp
type SMTPSender struct {
	config SMTPConfig
}

// NewSMTPSender creates a new instance of SMTPSender
func NewSMTPSender(config SMTPConfig) *SMTPSender {
	return &SMTPSender{config: config}
}

type EmailRequest struct {
	To      []string
	Subject string
	Body    string
	IsHTML  bool // Toggle this to true for HTML emails
}

// SendEmail delivers one message with a bounded dial and an overall deadline, so a slow or hung
// SMTP server fails the call instead of hanging it.
func (s *SMTPSender) SendEmail(req *EmailRequest) error {
	fail := func(err error) error { return fmt.Errorf("failed to send email: %w", err) }

	contentType := "text/plain"
	if req.IsHTML {
		contentType = "text/html"
	}
	msg := fmt.Sprintf("From: %s\r\n"+
		"To: %s\r\n"+
		"Subject: %s\r\n"+
		"MIME-Version: 1.0\r\n"+
		"Content-Type: %s; charset=\"UTF-8\"\r\n"+
		"\r\n"+
		"%s\r\n", s.config.From, strings.Join(req.To, ","), req.Subject, contentType, req.Body)

	conn, err := net.DialTimeout("tcp", net.JoinHostPort(s.config.Host, s.config.Port), dialTimeout)
	if err != nil {
		return fail(err)
	}
	defer conn.Close()
	if err := conn.SetDeadline(time.Now().Add(sendTimeout)); err != nil {
		return fail(err)
	}

	client, err := smtp.NewClient(conn, s.config.Host)
	if err != nil {
		return fail(err)
	}
	defer client.Close()

	if ok, _ := client.Extension("STARTTLS"); ok {
		if err := client.StartTLS(&tls.Config{ServerName: s.config.Host}); err != nil {
			return fail(err)
		}
	}
	// Local relays (Mailpit) take no auth, and net/smtp refuses PLAIN auth over plaintext to
	// non-localhost hosts, so only authenticate when credentials are configured.
	if s.config.Username != "" {
		if err := client.Auth(smtp.PlainAuth("", s.config.Username, s.config.Password, s.config.Host)); err != nil {
			return fail(err)
		}
	}

	if err := client.Mail(s.config.From); err != nil {
		return fail(err)
	}
	for _, to := range req.To {
		if err := client.Rcpt(to); err != nil {
			return fail(err)
		}
	}
	w, err := client.Data()
	if err != nil {
		return fail(err)
	}
	if _, err := w.Write([]byte(msg)); err != nil {
		return fail(err)
	}
	if err := w.Close(); err != nil {
		return fail(err)
	}
	return client.Quit()
}

package email

import (
	"fmt"
	"net/smtp"
	"strings"
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

func (s *SMTPSender) SendEmail(req *EmailRequest) error {
	// 1. Setup Authentication
	auth := smtp.PlainAuth("", s.config.Username, s.config.Password, s.config.Host)

	// 2. Determine Content Type
	contentType := "text/plain"
	if req.IsHTML {
		contentType = "text/html"
	}

	// 3. Format the SMTP address
	addr := fmt.Sprintf("%s:%s", s.config.Host, s.config.Port)

	// 4. Construct the message headers and body
	// We use the determined contentType here
	headers := fmt.Sprintf("To: %s\r\n"+
		"Subject: %s\r\n"+
		"MIME-Version: 1.0\r\n"+
		"Content-Type: %s; charset=\"UTF-8\"\r\n"+
		"\r\n"+
		"%s\r\n", strings.Join(req.To, ","), req.Subject, contentType, req.Body)

	msg := []byte(headers)

	// 5. Send the email
	err := smtp.SendMail(addr, auth, s.config.From, req.To, msg)
	if err != nil {
		return fmt.Errorf("failed to send email: %w", err)
	}

	return nil
}

package logs

import (
	"go-skeleton/pkg/clients/http"
	"os"
	"runtime/debug"
	"time"

	"github.com/sirupsen/logrus"
)

type Logger struct {
	*logrus.Logger
	pushURL string
	client  *http.Client
}

var Log *Logger

type Fields = logrus.Fields

// Init initializes logger output to console + optional remote push
func Init(serverlessURL string) {
	l := logrus.New()
	l.SetOutput(os.Stdout)
	l.SetFormatter(&logrus.JSONFormatter{TimestampFormat: time.RFC3339})

	Log = &Logger{
		Logger:  l,
		pushURL: serverlessURL,
		client:  http.NewClientBuilder().Build(),
	}
}

// Push structured log externally (HTTP or notification service)
func (l *Logger) push(collection string, data logrus.Fields) {
	if l.pushURL == "" {
		return
	}

	data["created_at"] = time.Now().Format(time.RFC3339)

	_, _ = l.client.Post(l.pushURL,
		&http.RequestOptions{
			Headers: map[string]string{
				"Content-Type": "application/json",
			},
			Body: data},
	)
}

// Standard exported functions
func Info(msg string, f Fields)  { Log.WithFields(f).Info(msg); Log.push("info", f) }
func Error(msg string, f Fields) { Log.WithFields(f).Error(msg); Log.push("error", f) }
func Debug(msg string, f Fields) { Log.WithFields(f).Debug(msg); Log.push("debug", f) }
func Activity(f Fields)          { Log.push("activity", f) }

// Panic log with stack trace
func Panic(err interface{}, f Fields) {
	f["stack"] = string(debug.Stack())
	f["panic"] = err
	Log.WithFields(f).Error("PANIC")
	Log.push("error", f)
}

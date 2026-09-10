package config

import (
	"fmt"

	"github.com/caarlos0/env/v6"
	"github.com/joho/godotenv"

	"go-skeleton/pkg/utils/file"
	"go-skeleton/pkg/utils/json"
)

// Config global setting
var Config = struct {
	DB struct {
		Username     string `env:"DB_USERNAME" envDefault:""`
		Password     string `env:"DB_PASSWORD" envDefault:""`
		Name         string `env:"DB_NAME" envDefault:""`
		Host         string `env:"DB_HOST" envDefault:"db"`
		Port         string `env:"DB_PORT" envDefault:"3306"`
		Encoding     string `env:"DB_ENCODING" envDefault:"utf8mb4"`
		Maxconns     uint64 `env:"DB_MAXCONNS" envDefault:"10"`
		Maxidleconns uint64 `env:"DB_MAXIDLECONNS" envDefault:"10"`
		Timeout      uint64 `env:"DB_TIMEOUNT" envDefault:"5000"`
		Debug        bool   `env:"DB_DEBUG" envDefault:"true"`
		SSLMode      string `env:"DB_SSLMODE" envDefault:"disable"`
		TimeZone     string `env:"DB_TIMEZONE" envDefault:"Asia/Jakarta"`
	}

	Redis struct {
		Address    string `env:"REDIS_ADDRESS" envDefault:"127.0.0.1:6379"`
		Password   string `env:"REDIS_PASSWORD" envDefault:""`
		DB         int    `env:"REDIS_DB" envDefault:"0"`
		TLSEnabled bool   `env:"REDIS_TLS_ENABLED" envDefault:"false"`
	}

	SMTP struct {
		Host     string `env:"SMTP_HOST" envDefault:"localhost"`
		Port     string `env:"SMTP_PORT" envDefault:"2740"`
		Username string `env:"SMTP_USERNAME" envDefault:"eg@example.com"`
		Password string `env:"SMTP_PASSWORD" envDefault:"password"`
		From     string `env:"SMTP_FROM" envDefault:"eg@example.com"`
	}

	System struct {
		AppName   string `env:"SYSTEM_APP_NAME" envDefault:"go-skeleton"`
		AppServer string `env:"SYSTEM_SERVER" envDefault:"127.0.0.1"`
		AppAddr   string `env:"SYSTEM_ADDR" envDefault:":7000"`
		Mode      string `env:"SYSTEM_MODE" envDefault:"debug"`
		TimeZone  string `env:"SYSTEM_TIME_ZONE" envDefault:"Asia/Jakarta"`
	}

	MiddlewareKeys struct {
		StaticAPIKey string `env:"STATIC_API_KEY" envDefault:"secret"`
	}

	PASETO struct {
		AccessSecret     string `env:"PASETO_ACCESS_SECRET" envDefault:""`
		RefreshSecret    string `env:"PASETO_REFRESH_SECRET" envDefault:""`
		AccessExpiryMin  int    `env:"PASETO_ACCESS_EXPIRY_MINUTES" envDefault:"15"`
		RefreshExpiryDay int    `env:"PASETO_REFRESH_EXPIRY_DAYS" envDefault:"7"`
	}
}{}

// Init initialize config
func Init() {
	if file.Exists("./.env") {
		if err := godotenv.Load(); err != nil {
			panic(err)
		}
	}

	if err := env.Parse(&Config); err != nil {
		panic(err)
	}
}

// Show for cli print setting
func Show() {
	Init()
	str, _ := json.MarshalIndent(Config, "", " ")
	fmt.Printf("Config: %s\n", str)
}

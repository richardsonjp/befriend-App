package config

import (
	"fmt"

	"github.com/caarlos0/env/v6"
	"github.com/joho/godotenv"

	"befriend/pkg/utils/file"
	"befriend/pkg/utils/json"
)

// Config global setting
var Config = struct {
	DB struct {
		Username     string `env:"DB_USERNAME" envDefault:""`
		Password     string `env:"DB_PASSWORD" envDefault:""`
		Name         string `env:"DB_NAME" envDefault:""`
		Host         string `env:"DB_HOST" envDefault:"db"`
		Port         string `env:"DB_PORT" envDefault:"5432"`
		Encoding     string `env:"DB_ENCODING" envDefault:"utf8mb4"`
		Maxconns     uint64 `env:"DB_MAXCONNS" envDefault:"10"`
		Maxidleconns uint64 `env:"DB_MAXIDLECONNS" envDefault:"10"`
		Timeout      uint64 `env:"DB_TIMEOUNT" envDefault:"5000"`
		Debug        bool   `env:"DB_DEBUG" envDefault:"true"`
		SSLMode      string `env:"DB_SSLMODE" envDefault:"disable"`
		TimeZone     string `env:"DB_TIMEZONE" envDefault:"Asia/Jakarta"`
	}

	SMTP struct {
		Host     string `env:"SMTP_HOST" envDefault:"localhost"`
		Port     string `env:"SMTP_PORT" envDefault:"1025"` // Mailpit
		Username string `env:"SMTP_USERNAME" envDefault:""`
		Password string `env:"SMTP_PASSWORD" envDefault:""`
		From     string `env:"SMTP_FROM" envDefault:"befriend@localhost"`
	}

	System struct {
		AppName     string `env:"SYSTEM_APP_NAME" envDefault:"befriend"`
		AppServer   string `env:"SYSTEM_SERVER" envDefault:"127.0.0.1"`
		AppAddr     string `env:"SYSTEM_ADDR" envDefault:":8305"`
		Mode        string `env:"SYSTEM_MODE" envDefault:"debug"`
		TimeZone    string `env:"SYSTEM_TIME_ZONE" envDefault:"Asia/Jakarta"`
		ProxyHeader string `env:"SYSTEM_PROXY_HEADER" envDefault:""`
		// IPs/CIDRs allowed to set ProxyHeader; from anyone else the header is ignored.
		TrustedProxies []string `env:"SYSTEM_TRUSTED_PROXIES" envSeparator:","`
	}

	MiddlewareKeys struct {
		StaticAPIKey string `env:"STATIC_API_KEY" envDefault:"secret"`
	}

	RateLimit struct {
		AuthPerMinute int `env:"AUTH_RATE_LIMIT_PER_MINUTE" envDefault:"10"`
	}

	Verification struct {
		ResendCooldownSec int `env:"VERIFICATION_RESEND_COOLDOWN_SECONDS" envDefault:"60"`
	}

	// In-App Purchases of skins. Environments are the App Store environments whose purchases count: Production at
	// launch; add Sandbox to test with TestFlight or sandbox accounts. Products are <ProductPrefix>.t<tier>.<nnn>.
	AppStore struct {
		BundleID      string   `env:"APPSTORE_BUNDLE_ID" envDefault:"com.richardsonjp.befriend"`
		Environments  []string `env:"APPSTORE_ENVIRONMENTS" envSeparator:"," envDefault:"Production"`
		ProductPrefix string   `env:"APPSTORE_PRODUCT_PREFIX" envDefault:"com.richardsonjp.befriend.skin"`
	}

	// Sign in with Apple. BundleIDs are the accepted token audiences; empty disables Apple sign-in.
	// TeamID/KeyID/PrivateKey (.p8) enable exchanging codes for Apple refresh tokens (needed to revoke on
	// account deletion). JWKSURL/Issuers only change for local end-to-end tests.
	Apple struct {
		BundleIDs  []string `env:"APPLE_BUNDLE_IDS" envSeparator:","`
		TeamID     string   `env:"APPLE_TEAM_ID" envDefault:""`
		KeyID      string   `env:"APPLE_KEY_ID" envDefault:""`
		PrivateKey string   `env:"APPLE_PRIVATE_KEY" envDefault:""`
		JWKSURL    string   `env:"APPLE_JWKS_URL" envDefault:"https://appleid.apple.com/auth/keys"`
		Issuers    []string `env:"APPLE_ISSUERS" envSeparator:"," envDefault:"https://appleid.apple.com"`
	}

	// Google sign-in. ClientIDs are the accepted token audiences (iOS and macOS OAuth clients); empty disables it.
	Google struct {
		ClientIDs []string `env:"GOOGLE_CLIENT_IDS" envSeparator:","`
		JWKSURL   string   `env:"GOOGLE_JWKS_URL" envDefault:"https://www.googleapis.com/oauth2/v3/certs"`
		Issuers   []string `env:"GOOGLE_ISSUERS" envSeparator:"," envDefault:"https://accounts.google.com,accounts.google.com"`
	}

	// OpenRouter generates personalities. Without an API key the generation queue simply waits.
	// BaseURL only changes for local end-to-end tests.
	OpenRouter struct {
		APIKey string `env:"OPENROUTER_API_KEY" envDefault:""`
		// Free on Requesty; tried in order. leanstral hatches a friend in ~40 s; nemotron-3-ultra is slower and
		// sometimes skips a moment. gemma-4-31b and nemotron-3-super run out of tokens on the full prompt.
		Models  []string `env:"OPENROUTER_MODELS" envSeparator:"," envDefault:"mistral/leanstral-1-5,nvidia/nemotron-3-ultra-550b-a55b"`
		BaseURL string   `env:"OPENROUTER_BASE_URL" envDefault:"https://router.requesty.ai/v1"` // any OpenAI-compatible router
	}

	// LLM request budget and generation worker. Caps sit under OpenRouter's free-tier limits (about
	// 20/minute and 50/day without purchased credits; check your account) and count every request.
	LLM struct {
		MinuteCap         int `env:"LLM_MINUTE_CAP" envDefault:"16"`
		DailyCap          int `env:"LLM_DAILY_CAP" envDefault:"45"`
		WorkerIntervalSec int `env:"LLM_WORKER_INTERVAL_SECONDS" envDefault:"10"`
		BatchSize         int `env:"LLM_WORKER_BATCH_SIZE" envDefault:"2"`
		// Weekly evolutions stop this many requests short of the daily cap, so new users can still hatch.
		OnboardingReserve int `env:"LLM_ONBOARDING_RESERVE" envDefault:"10"`
	}

	// APNs token authentication (a .p8 key with Apple Push Notifications service enabled). Without it presence
	// still works, but iPhone Live Activities and widgets aren't pushed.
	APNs struct {
		TeamID     string `env:"APNS_TEAM_ID" envDefault:""`
		KeyID      string `env:"APNS_KEY_ID" envDefault:""`
		PrivateKey string `env:"APNS_PRIVATE_KEY" envDefault:""`
		BundleID   string `env:"APNS_BUNDLE_ID" envDefault:"com.richardsonjp.befriend"`
	}

	Presence struct {
		SweepIntervalSec int `env:"PRESENCE_SWEEP_INTERVAL_SECONDS" envDefault:"30"`
	}

	PASETO struct {
		AccessSecret         string `env:"PASETO_ACCESS_SECRET" envDefault:""`
		RefreshSecret        string `env:"PASETO_REFRESH_SECRET" envDefault:""`
		AccessExpiryMin      int    `env:"PASETO_ACCESS_EXPIRY_MINUTES" envDefault:"15"`
		RefreshExpiryDay     int    `env:"PASETO_REFRESH_EXPIRY_DAYS" envDefault:"7"`
		RefreshReuseGraceSec int    `env:"PASETO_REFRESH_REUSE_GRACE_SECONDS" envDefault:"60"`
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

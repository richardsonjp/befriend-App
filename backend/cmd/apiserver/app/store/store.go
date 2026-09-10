package store

import (
	"befriend/config"
	"befriend/pkg/clients/db"
	"befriend/pkg/clients/email"
	"befriend/pkg/clients/redis"
	"befriend/pkg/utils/logs"

	// Repositories
	reposDevice "befriend/internal/repositories/device"
	reposRefreshToken "befriend/internal/repositories/refresh_token"
	reposTx "befriend/internal/repositories/tx"
	reposUser "befriend/internal/repositories/user"
	reposVerificationCode "befriend/internal/repositories/verification_code"

	// Services
	serviceAuthentication "befriend/internal/services/authentication"
	serviceDevice "befriend/internal/services/device"
	serviceRefreshToken "befriend/internal/services/refresh_token"
	serviceUser "befriend/internal/services/user"
	serviceUserApplication "befriend/internal/services/user_application"
	serviceVerificationCode "befriend/internal/services/verification_code"

	// Handlers
	handlerUser "befriend/cmd/apiserver/app/handlers/user"
	handlerUserAuth "befriend/cmd/apiserver/app/handlers/user_auth"

	// Middlewares
	"befriend/internal/middlewares"
)

type Store struct {
	DB    db.DBGormDelegate
	Redis redis.RedisDelegate
	Email email.EmailSender
	Log   *logs.Logger

	// Handlers
	UserAuthHandler *handlerUserAuth.UserAuthHandler
	UserHandler     *handlerUser.UserHandler

	// Middleware
	MiddlewarePasetoAuth middlewares.MiddlewarePasetoAuth
}

// Global instance
var App *Store

func Init() {
	// Initialize Logger
	logs.Init(config.Config.System.AppServer)

	// Fail fast: tokens signed with an empty secret would be forgeable.
	if config.Config.PASETO.AccessSecret == "" || config.Config.PASETO.RefreshSecret == "" {
		panic("PASETO_ACCESS_SECRET and PASETO_REFRESH_SECRET must be set")
	}

	// Core dependencies
	db := db.NewDBdelegate(config.Config.DB.Debug)
	db.Init()
	redis := redis.NewRedisDel()
	redis.Init()
	smtpClient := email.NewSMTPSender(email.SMTPConfig{
		Host:     config.Config.SMTP.Host,
		Port:     config.Config.SMTP.Port,
		Username: config.Config.SMTP.Username,
		Password: config.Config.SMTP.Password,
		From:     config.Config.SMTP.From,
	})

	// Repos
	txRepo := reposTx.NewTxRepo(db)
	userRepo := reposUser.NewUserRepo(db)
	deviceRepo := reposDevice.NewDeviceRepo(db)
	refreshTokenRepo := reposRefreshToken.NewRefreshTokenRepo(db)
	verificationCodeRepo := reposVerificationCode.NewVerificationCodeRepo(db)

	// Services
	userService := serviceUser.NewUserService(txRepo, userRepo)
	deviceService := serviceDevice.NewDeviceService(txRepo, deviceRepo)
	refreshTokenService := serviceRefreshToken.NewRefreshTokenService(txRepo, refreshTokenRepo)
	verificationCodeService := serviceVerificationCode.NewVerificationCodeService(txRepo, verificationCodeRepo, smtpClient)
	userApplicationService := serviceUserApplication.NewUserApplicationService(txRepo, userService, verificationCodeService)
	authenticationService := serviceAuthentication.NewAuthenticationService(txRepo, userService, deviceService, refreshTokenService)

	App = &Store{
		DB:    db,
		Redis: redis,
		Email: smtpClient,
		Log:   logs.Log,

		UserAuthHandler: handlerUserAuth.NewUserAuthHandler(authenticationService),
		UserHandler:     handlerUser.NewUserHandler(userApplicationService),

		MiddlewarePasetoAuth: middlewares.NewMiddlewarePasetoAuth(),
	}
}

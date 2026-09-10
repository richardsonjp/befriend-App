package store

import (
	"context"

	"befriend/config"
	"befriend/pkg/clients/apple"
	"befriend/pkg/clients/db"
	"befriend/pkg/clients/email"
	"befriend/pkg/clients/idtoken"
	"befriend/pkg/clients/openrouter"
	"befriend/pkg/clients/redis"
	"befriend/pkg/utils/logs"

	// Repositories
	reposDevice "befriend/internal/repositories/device"
	reposFriend "befriend/internal/repositories/friend"
	reposLLMBudget "befriend/internal/repositories/llm_budget"
	reposOnboardingResponse "befriend/internal/repositories/onboarding_response"
	reposPersonalityVersion "befriend/internal/repositories/personality_version"
	reposQuestionSet "befriend/internal/repositories/question_set"
	reposRefreshToken "befriend/internal/repositories/refresh_token"
	reposTx "befriend/internal/repositories/tx"
	reposUser "befriend/internal/repositories/user"
	reposUserIdentity "befriend/internal/repositories/user_identity"
	reposVerificationCode "befriend/internal/repositories/verification_code"

	// Services
	serviceAuthentication "befriend/internal/services/authentication"
	serviceDevice "befriend/internal/services/device"
	serviceFriend "befriend/internal/services/friend"
	serviceOnboarding "befriend/internal/services/onboarding"
	servicePersonality "befriend/internal/services/personality"
	servicePersonalityVersion "befriend/internal/services/personality_version"
	serviceQuestionSet "befriend/internal/services/question_set"
	serviceRefreshToken "befriend/internal/services/refresh_token"
	serviceUser "befriend/internal/services/user"
	serviceUserApplication "befriend/internal/services/user_application"
	serviceUserIdentity "befriend/internal/services/user_identity"
	serviceVerificationCode "befriend/internal/services/verification_code"

	// Handlers
	handlerFriend "befriend/cmd/apiserver/app/handlers/friend"
	handlerOnboarding "befriend/cmd/apiserver/app/handlers/onboarding"
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

	// Background work
	PersonalityService servicePersonality.PersonalityService

	// Handlers
	UserAuthHandler   *handlerUserAuth.UserAuthHandler
	UserHandler       *handlerUser.UserHandler
	OnboardingHandler *handlerOnboarding.OnboardingHandler
	FriendHandler     *handlerFriend.FriendHandler

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

	// Sign in with Apple / Google: nil verifiers when no audiences are configured (the endpoints then
	// answer "not configured"). Key sets refresh in the background for the life of the process.
	appleVerifier, err := idtoken.New(context.Background(), idtoken.Config{
		JWKSURL:   config.Config.Apple.JWKSURL,
		Issuers:   config.Config.Apple.Issuers,
		Audiences: config.Config.Apple.BundleIDs,
		HashNonce: true,
	})
	if err != nil {
		panic("init apple identity verifier: " + err.Error())
	}
	googleVerifier, err := idtoken.New(context.Background(), idtoken.Config{
		JWKSURL:   config.Config.Google.JWKSURL,
		Issuers:   config.Config.Google.Issuers,
		Audiences: config.Config.Google.ClientIDs,
	})
	if err != nil {
		panic("init google identity verifier: " + err.Error())
	}
	appleClient, err := apple.New(apple.Config{
		TeamID:        config.Config.Apple.TeamID,
		KeyID:         config.Config.Apple.KeyID,
		PrivateKeyPEM: config.Config.Apple.PrivateKey,
	})
	if err != nil {
		panic("init apple client: " + err.Error())
	}

	// Personality generation: nil client without an API key, so friends wait with a pending personality.
	openRouterClient := openrouter.New(openrouter.Config{
		BaseURL: config.Config.OpenRouter.BaseURL,
		APIKey:  config.Config.OpenRouter.APIKey,
		Models:  config.Config.OpenRouter.Models,
		AppName: config.Config.System.AppName,
	})
	if openRouterClient == nil {
		logs.Log.Warn("OPENROUTER_API_KEY is not set: personalities stay pending until it is")
	}

	// Repos
	txRepo := reposTx.NewTxRepo(db)
	userRepo := reposUser.NewUserRepo(db)
	userIdentityRepo := reposUserIdentity.NewUserIdentityRepo(db)
	deviceRepo := reposDevice.NewDeviceRepo(db)
	refreshTokenRepo := reposRefreshToken.NewRefreshTokenRepo(db)
	verificationCodeRepo := reposVerificationCode.NewVerificationCodeRepo(db)
	questionSetRepo := reposQuestionSet.NewQuestionSetRepo(db)
	onboardingResponseRepo := reposOnboardingResponse.NewOnboardingResponseRepo(db)
	friendRepo := reposFriend.NewFriendRepo(db)
	personalityVersionRepo := reposPersonalityVersion.NewPersonalityVersionRepo(db)
	llmBudgetRepo := reposLLMBudget.NewLLMBudgetRepo(redis)

	// Services
	userService := serviceUser.NewUserService(txRepo, userRepo)
	userIdentityService := serviceUserIdentity.NewUserIdentityService(txRepo, userIdentityRepo)
	deviceService := serviceDevice.NewDeviceService(txRepo, deviceRepo)
	refreshTokenService := serviceRefreshToken.NewRefreshTokenService(txRepo, refreshTokenRepo)
	verificationCodeService := serviceVerificationCode.NewVerificationCodeService(txRepo, verificationCodeRepo, smtpClient)
	questionSetService := serviceQuestionSet.NewQuestionSetService(txRepo, questionSetRepo)
	personalityVersionService := servicePersonalityVersion.NewPersonalityVersionService(txRepo, personalityVersionRepo)
	friendService := serviceFriend.NewFriendService(txRepo, friendRepo, personalityVersionService)
	onboardingService := serviceOnboarding.NewOnboardingService(
		txRepo,
		onboardingResponseRepo,
		questionSetService,
		friendService,
		personalityVersionService,
	)
	personalityService := servicePersonality.NewPersonalityService(
		txRepo,
		llmBudgetRepo,
		personalityVersionService,
		friendService,
		onboardingService,
		openRouterClient,
	)
	userApplicationService := serviceUserApplication.NewUserApplicationService(txRepo, userService, verificationCodeService, friendService)
	authenticationService := serviceAuthentication.NewAuthenticationService(
		txRepo,
		userService,
		userIdentityService,
		deviceService,
		refreshTokenService,
		appleVerifier,
		googleVerifier,
		appleClient,
	)

	App = &Store{
		DB:    db,
		Redis: redis,
		Email: smtpClient,
		Log:   logs.Log,

		PersonalityService: personalityService,

		UserAuthHandler:   handlerUserAuth.NewUserAuthHandler(authenticationService),
		UserHandler:       handlerUser.NewUserHandler(userApplicationService),
		OnboardingHandler: handlerOnboarding.NewOnboardingHandler(onboardingService),
		FriendHandler:     handlerFriend.NewFriendHandler(friendService),

		MiddlewarePasetoAuth: middlewares.NewMiddlewarePasetoAuth(),
	}
}

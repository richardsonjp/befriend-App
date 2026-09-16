package store

import (
	"context"

	"befriend/config"
	"befriend/pkg/clients/apns"
	"befriend/pkg/clients/apple"
	"befriend/pkg/clients/db"
	"befriend/pkg/clients/email"
	"befriend/pkg/clients/idtoken"
	"befriend/pkg/clients/openrouter"
	"befriend/pkg/utils/logs"

	// Repositories
	reposDevice "befriend/internal/repositories/device"
	reposFriend "befriend/internal/repositories/friend"
	reposLLMBudget "befriend/internal/repositories/llm_budget"
	reposOnboardingResponse "befriend/internal/repositories/onboarding_response"
	reposPairingCode "befriend/internal/repositories/pairing_code"
	reposPersonalityVersion "befriend/internal/repositories/personality_version"
	reposPresence "befriend/internal/repositories/presence"
	reposQuestionSet "befriend/internal/repositories/question_set"
	reposRefreshToken "befriend/internal/repositories/refresh_token"
	reposSkin "befriend/internal/repositories/skin"
	reposTriggerEvent "befriend/internal/repositories/trigger_event"
	reposTx "befriend/internal/repositories/tx"
	reposUser "befriend/internal/repositories/user"
	reposUserIdentity "befriend/internal/repositories/user_identity"
	reposVerificationCode "befriend/internal/repositories/verification_code"

	// Services
	serviceAuthentication "befriend/internal/services/authentication"
	serviceDevice "befriend/internal/services/device"
	serviceEvolution "befriend/internal/services/evolution"
	serviceFriend "befriend/internal/services/friend"
	serviceOnboarding "befriend/internal/services/onboarding"
	servicePairingCode "befriend/internal/services/pairing_code"
	servicePersonality "befriend/internal/services/personality"
	servicePersonalityVersion "befriend/internal/services/personality_version"
	servicePresence "befriend/internal/services/presence"
	serviceQuestionSet "befriend/internal/services/question_set"
	serviceRefreshToken "befriend/internal/services/refresh_token"
	serviceSkin "befriend/internal/services/skin"
	serviceTriggerEvent "befriend/internal/services/trigger_event"
	serviceUser "befriend/internal/services/user"
	serviceUserApplication "befriend/internal/services/user_application"
	serviceUserIdentity "befriend/internal/services/user_identity"
	serviceVerificationCode "befriend/internal/services/verification_code"

	// Handlers
	handlerDevice "befriend/cmd/apiserver/app/handlers/device"
	handlerFriend "befriend/cmd/apiserver/app/handlers/friend"
	handlerOnboarding "befriend/cmd/apiserver/app/handlers/onboarding"
	handlerPairing "befriend/cmd/apiserver/app/handlers/pairing"
	handlerPresence "befriend/cmd/apiserver/app/handlers/presence"
	handlerSkin "befriend/cmd/apiserver/app/handlers/skin"
	handlerTriggerEvent "befriend/cmd/apiserver/app/handlers/trigger_event"
	handlerUser "befriend/cmd/apiserver/app/handlers/user"
	handlerUserAuth "befriend/cmd/apiserver/app/handlers/user_auth"

	// Middlewares
	"befriend/internal/middlewares"
)

type Store struct {
	DB    db.DBGormDelegate
	Email email.EmailSender
	Log   *logs.Logger

	// Background work
	PersonalityService servicePersonality.PersonalityService
	PresenceService    servicePresence.PresenceService
	EvolutionService   serviceEvolution.EvolutionService

	// CLI (apiserver skin …, apiserver harvest …)
	SkinService        serviceSkin.SkinService
	QuestionSetService serviceQuestionSet.QuestionSetService

	// Handlers
	UserAuthHandler     *handlerUserAuth.UserAuthHandler
	UserHandler         *handlerUser.UserHandler
	OnboardingHandler   *handlerOnboarding.OnboardingHandler
	FriendHandler       *handlerFriend.FriendHandler
	DeviceHandler       *handlerDevice.DeviceHandler
	PairingHandler      *handlerPairing.PairingHandler
	TriggerEventHandler *handlerTriggerEvent.TriggerEventHandler
	PresenceHandler     *handlerPresence.PresenceHandler
	SkinHandler         *handlerSkin.SkinHandler

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

	// Live Activity and widget pushes: nil client without APNs credentials, so presence works without pushes.
	apnsClient, err := apns.New(apns.Config{
		TeamID:        config.Config.APNs.TeamID,
		KeyID:         config.Config.APNs.KeyID,
		PrivateKeyPEM: config.Config.APNs.PrivateKey,
		BundleID:      config.Config.APNs.BundleID,
	})
	if err != nil {
		panic("init apns client: " + err.Error())
	}
	if apnsClient == nil {
		logs.Log.Warn("APNS_* is not set: iPhone Live Activities and widgets won't be pushed")
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
	pairingCodeRepo := reposPairingCode.NewPairingCodeRepo(db)
	triggerEventRepo := reposTriggerEvent.NewTriggerEventRepo(db)
	presenceRepo := reposPresence.NewPresenceRepo(db)
	llmBudgetRepo := reposLLMBudget.NewLLMBudgetRepo(db)
	skinRepo := reposSkin.NewSkinRepo(db)

	// Services
	userService := serviceUser.NewUserService(txRepo, userRepo)
	userIdentityService := serviceUserIdentity.NewUserIdentityService(txRepo, userIdentityRepo)
	deviceService := serviceDevice.NewDeviceService(txRepo, deviceRepo)
	refreshTokenService := serviceRefreshToken.NewRefreshTokenService(txRepo, refreshTokenRepo)
	verificationCodeService := serviceVerificationCode.NewVerificationCodeService(txRepo, verificationCodeRepo, smtpClient)
	questionSetService := serviceQuestionSet.NewQuestionSetService(txRepo, questionSetRepo)
	personalityVersionService := servicePersonalityVersion.NewPersonalityVersionService(txRepo, personalityVersionRepo)
	pairingCodeService := servicePairingCode.NewPairingCodeService(txRepo, pairingCodeRepo)
	triggerEventService := serviceTriggerEvent.NewTriggerEventService(txRepo, triggerEventRepo, userService)
	friendService := serviceFriend.NewFriendService(txRepo, friendRepo, personalityVersionService)
	presenceService := servicePresence.NewPresenceService(txRepo, presenceRepo, deviceService, friendService, apnsClient)
	skinService := serviceSkin.NewSkinService(txRepo, skinRepo, userService)
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
		triggerEventService,
		openRouterClient,
	)
	evolutionService := serviceEvolution.NewEvolutionService(
		txRepo,
		friendService,
		personalityVersionService,
		personalityService,
		triggerEventService,
		pairingCodeService,
	)
	userApplicationService := serviceUserApplication.NewUserApplicationService(
		txRepo,
		userService,
		verificationCodeService,
		friendService,
		triggerEventService,
		skinService,
	)
	authenticationService := serviceAuthentication.NewAuthenticationService(
		txRepo,
		userService,
		userIdentityService,
		deviceService,
		refreshTokenService,
		pairingCodeService,
		appleVerifier,
		googleVerifier,
		appleClient,
	)

	App = &Store{
		DB:    db,
		Email: smtpClient,
		Log:   logs.Log,

		PersonalityService: personalityService,
		PresenceService:    presenceService,
		EvolutionService:   evolutionService,

		SkinService:        skinService,
		QuestionSetService: questionSetService,

		UserAuthHandler:     handlerUserAuth.NewUserAuthHandler(authenticationService),
		UserHandler:         handlerUser.NewUserHandler(userApplicationService),
		OnboardingHandler:   handlerOnboarding.NewOnboardingHandler(onboardingService),
		FriendHandler:       handlerFriend.NewFriendHandler(friendService),
		DeviceHandler:       handlerDevice.NewDeviceHandler(deviceService),
		PairingHandler:      handlerPairing.NewPairingHandler(pairingCodeService, authenticationService),
		TriggerEventHandler: handlerTriggerEvent.NewTriggerEventHandler(triggerEventService),
		PresenceHandler:     handlerPresence.NewPresenceHandler(presenceService),
		SkinHandler:         handlerSkin.NewSkinHandler(skinService),

		MiddlewarePasetoAuth: middlewares.NewMiddlewarePasetoAuth(),
	}
}

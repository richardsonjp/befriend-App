package store

import (
	"befriend/config"
	"befriend/pkg/clients/db"
	"befriend/pkg/clients/email"
	"befriend/pkg/clients/redis"
	"befriend/pkg/utils/logs"

	// Repositories
	reposAccount "befriend/internal/repositories/account"
	reposAccountMember "befriend/internal/repositories/account_member"
	reposAppResource "befriend/internal/repositories/app_resource"
	reposKycRequest "befriend/internal/repositories/kyc_request"
	reposOperator "befriend/internal/repositories/operator"
	reposOperatorAuditLog "befriend/internal/repositories/operator_audit_log"
	reposPermission "befriend/internal/repositories/permission"
	reposPermissionCategory "befriend/internal/repositories/permission_category"
	reposRefreshToken "befriend/internal/repositories/refresh_token"
	reposRole "befriend/internal/repositories/role"
	reposRolePermission "befriend/internal/repositories/role_permission"
	reposTx "befriend/internal/repositories/tx"
	reposUser "befriend/internal/repositories/user"
	reposVerificationCode "befriend/internal/repositories/verification_code"

	// Services
	serviceAccount "befriend/internal/services/account"
	serviceAccountMember "befriend/internal/services/account_member"
	serviceAppResource "befriend/internal/services/app_resource"
	serviceAuthentication "befriend/internal/services/authentication"
	serviceOperator "befriend/internal/services/operator"
	servicePermission "befriend/internal/services/permission"
	servicePermissionCategory "befriend/internal/services/permission_category"
	serviceRefreshToken "befriend/internal/services/refresh_token"
	serviceRole "befriend/internal/services/role"
	serviceRolePermission "befriend/internal/services/role_permission"
	serviceUser "befriend/internal/services/user"
	serviceUserApplication "befriend/internal/services/user_application"
	serviceVerificationCode "befriend/internal/services/verification_code"

	// Handlers
	handlerOperatorAuth "befriend/cmd/apiserver/app/handlers/operator_auth"
	handlerRole "befriend/cmd/apiserver/app/handlers/role"
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

	// Repositories
	AccountRepo            reposAccount.AccountRepo
	AccountMemberRepo      reposAccountMember.AccountMemberRepo
	AppResourceRepo        reposAppResource.AppResourceRepo
	KycRequestRepo         reposKycRequest.KycRequestRepo
	OperatorRepo           reposOperator.OperatorRepo
	OperatorAuditLogRepo   reposOperatorAuditLog.OperatorAuditLogRepo
	PermissionRepo         reposPermission.PermissionRepo
	PermissionCategoryRepo reposPermissionCategory.PermissionCategoryRepo
	RefreshTokenRepo       reposRefreshToken.RefreshTokenRepo
	RoleRepo               reposRole.RoleRepo
	RolePermissionRepo     reposRolePermission.RolePermissionRepo
	UserRepo               reposUser.UserRepo
	VerificationCodeRepo   reposVerificationCode.VerificationCodeRepo

	// Services
	AccountService            serviceAccount.AccountService
	AccountMemberService      serviceAccountMember.AccountMemberService
	AppResourceService        serviceAppResource.AppResourceService
	AuthenticationService     serviceAuthentication.AuthenticationService
	OperatorService           serviceOperator.OperatorService
	PermissionService         servicePermission.PermissionService
	PermissionCategoryService servicePermissionCategory.PermissionCategoryService
	RefreshTokenService       serviceRefreshToken.RefreshTokenService
	RoleService               serviceRole.RoleService
	RolePermissionService     serviceRolePermission.RolePermissionService
	UserService               serviceUser.UserService
	UserApplicationService    serviceUserApplication.UserApplicationService
	VerificationCodeService   serviceVerificationCode.VerificationCodeService

	// Handlers
	UserAuthHandler     *handlerUserAuth.UserAuthHandler
	OperatorAuthHandler *handlerOperatorAuth.OperatorAuthHandler
	UserHandler         *handlerUser.UserHandler
	RoleHandler         *handlerRole.RoleHandler

	// Middleware
	MiddlewarePasetoAuth    middlewares.MiddlewarePasetoAuth
	MiddlewareAccessControl middlewares.MiddlewareAccessControl
}

// Global instance
var App *Store

func Init() {
	// Initialize Logger
	logs.Init(config.Config.System.AppServer)

	// Core dependencies
	db := db.NewDBdelegate(config.Config.DB.Debug)
	db.Init()
	redis := redis.NewRedisDel()
	//redis.Init()
	smtpClient := email.NewSMTPSender(email.SMTPConfig{
		Host:     config.Config.SMTP.Host,
		Port:     config.Config.SMTP.Port,
		Username: config.Config.SMTP.Username,
		Password: config.Config.SMTP.Password,
		From:     config.Config.SMTP.From,
	})

	// Repos
	accountRepo := reposAccount.NewAccountRepo(db)
	accountMemberRepo := reposAccountMember.NewAccountMemberRepo(db)
	appResourceRepo := reposAppResource.NewAppResourceRepo(db)
	kycRequestRepo := reposKycRequest.NewKycRequestRepo(db)
	operatorRepo := reposOperator.NewOperatorRepo(db)
	operatorAuditLogRepo := reposOperatorAuditLog.NewOperatorAuditLogRepo(db)
	permissionRepo := reposPermission.NewPermissionRepo(db)
	permissionCategoryRepo := reposPermissionCategory.NewPermissionCategoryRepo(db)
	refreshTokenRepo := reposRefreshToken.NewRefreshTokenRepo(db)
	roleRepo := reposRole.NewRoleRepo(db)
	rolePermissionRepo := reposRolePermission.NewRolePermissionRepo(db)
	userRepo := reposUser.NewUserRepo(db)
	verificationCodeRepo := reposVerificationCode.NewVerificationCodeRepo(db)

	txRepo := reposTx.NewTxRepo(db)

	// Services
	accountService := serviceAccount.NewAccountService(txRepo, accountRepo)
	accountMemberService := serviceAccountMember.NewAccountMemberService(accountMemberRepo)
	appResourceService := serviceAppResource.NewAppResourceService(txRepo, appResourceRepo)
	operatorService := serviceOperator.NewOperatorService(txRepo, operatorRepo)
	permissionService := servicePermission.NewPermissionService(txRepo, permissionRepo)
	permissionCategoryService := servicePermissionCategory.NewPermissionCategoryService(txRepo, permissionCategoryRepo)
	refreshTokenService := serviceRefreshToken.NewRefreshTokenService(txRepo, refreshTokenRepo)
	rolePermissionService := serviceRolePermission.NewRolePermissionService(txRepo, rolePermissionRepo)
	roleService := serviceRole.NewRoleService(txRepo, roleRepo, accountService, rolePermissionService, permissionService, permissionCategoryService)
	userService := serviceUser.NewUserService(txRepo, userRepo)
	verificationCodeService := serviceVerificationCode.NewVerificationCodeService(txRepo, verificationCodeRepo, smtpClient)
	userApplicationService := serviceUserApplication.NewUserApplicationService(txRepo, userService, roleService, accountService, accountMemberService, verificationCodeService)

	authenticationService := serviceAuthentication.NewAuthenticationService(
		txRepo,
		userService,
		operatorService,
		roleService,
		accountService,
		accountMemberService,
		appResourceService,
	)

	// Handlers
	userAuthHandler := handlerUserAuth.NewUserAuthHandler(authenticationService)
	operatorAuthHandler := handlerOperatorAuth.NewOperatorAuthHandler(authenticationService)
	userHandler := handlerUser.NewUserHandler(userApplicationService)
	roleHandler := handlerRole.NewRoleHandler(roleService)

	// Middleware
	mwPaseto := middlewares.NewMiddlewarePasetoAuth()
	mwAccessControl := middlewares.NewMiddlewareAccessControl(appResourceService, rolePermissionService)

	App = &Store{
		DB:    db,
		Redis: redis,
		Log:   logs.Log,

		AccountRepo:            accountRepo,
		AccountMemberRepo:      accountMemberRepo,
		AppResourceRepo:        appResourceRepo,
		KycRequestRepo:         kycRequestRepo,
		OperatorRepo:           operatorRepo,
		OperatorAuditLogRepo:   operatorAuditLogRepo,
		PermissionRepo:         permissionRepo,
		PermissionCategoryRepo: permissionCategoryRepo,
		RefreshTokenRepo:       refreshTokenRepo,
		RoleRepo:               roleRepo,
		RolePermissionRepo:     rolePermissionRepo,
		UserRepo:               userRepo,
		VerificationCodeRepo:   verificationCodeRepo,

		AccountService:            accountService,
		AuthenticationService:     authenticationService,
		OperatorService:           operatorService,
		PermissionService:         permissionService,
		PermissionCategoryService: permissionCategoryService,
		RefreshTokenService:       refreshTokenService,
		RoleService:               roleService,
		RolePermissionService:     rolePermissionService,
		UserService:               userService,
		VerificationCodeService:   verificationCodeService,

		UserAuthHandler:     userAuthHandler,
		OperatorAuthHandler: operatorAuthHandler,
		UserHandler:         userHandler,
		RoleHandler:         roleHandler,

		MiddlewarePasetoAuth:    mwPaseto,
		MiddlewareAccessControl: mwAccessControl,
	}
}

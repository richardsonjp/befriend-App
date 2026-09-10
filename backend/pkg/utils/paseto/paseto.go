package paseto

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"time"

	"go-skeleton/config"

	"aidanwoods.dev/go-paseto"
)

type Claims struct {
	UserID     string `json:"user_id,omitempty"`
	OperatorID string `json:"operator_id,omitempty"`
	RoleID     string `json:"role_id"`
}

// getSymmetricKey derives a 32-byte key from a string secret using SHA256
func getSymmetricKey(secret string) paseto.V4SymmetricKey {
	hash := sha256.Sum256([]byte(secret))
	hexKey := hex.EncodeToString(hash[:])
	key, err := paseto.V4SymmetricKeyFromHex(hexKey)
	if err != nil {
		// This should technically not happen with valid SHA256 output, but good to handle or panic safely
		panic("failed to generate symmetric key from secret: " + err.Error())
	}
	return key
}

// GenerateTokens generates access and refresh tokens for a user using PASETO v4
func GenerateTokens(data Claims) (string, string, error) {
	// Access Token
	accessToken := paseto.NewToken()
	if data.UserID != "" {
		accessToken.Set("user_id", data.UserID)
	}
	if data.OperatorID != "" {
		accessToken.Set("operator_id", data.OperatorID)
	}
	accessToken.Set("role_id", data.RoleID)
	accessToken.SetIssuer(config.Config.System.AppName)
	accessToken.SetIssuedAt(time.Now())
	accessToken.SetNotBefore(time.Now())
	accessToken.SetExpiration(time.Now().Add(time.Duration(config.Config.PASETO.AccessExpiryMin) * time.Minute))

	accessKey := getSymmetricKey(config.Config.PASETO.AccessSecret)
	encryptedAccess := accessToken.V4Encrypt(accessKey, nil)

	// Refresh Token
	refreshToken := paseto.NewToken()
	if data.UserID != "" {
		refreshToken.Set("user_id", data.UserID)
	}
	if data.OperatorID != "" {
		refreshToken.Set("operator_id", data.OperatorID)
	}
	refreshToken.Set("role_id", data.RoleID)
	refreshToken.SetIssuer(config.Config.System.AppName)
	refreshToken.SetIssuedAt(time.Now())
	refreshToken.SetNotBefore(time.Now())
	refreshToken.SetExpiration(time.Now().Add(time.Duration(config.Config.PASETO.RefreshExpiryDay) * 24 * time.Hour))

	refreshKey := getSymmetricKey(config.Config.PASETO.RefreshSecret)
	encryptedRefresh := refreshToken.V4Encrypt(refreshKey, nil)

	return encryptedAccess, encryptedRefresh, nil
}

// ValidateToken validates the token and returns the claims
func ValidateToken(tokenString string, secret string) (*Claims, error) {
	parser := paseto.NewParser()
	parser.AddRule(paseto.NotExpired())
	parser.AddRule(paseto.ValidAt(time.Now()))

	key := getSymmetricKey(secret)
	token, err := parser.ParseV4Local(key, tokenString, nil)
	if err != nil {
		return nil, err
	}

	userID, _ := token.GetString("user_id")
	operatorID, _ := token.GetString("operator_id")

	if userID == "" && operatorID == "" {
		return nil, errors.New("invalid token: missing identity (user_id or operator_id)")
	}

	roleID, err := token.GetString("role_id")
	if err != nil {
		return nil, errors.New("invalid token: missing role_id")
	}

	return &Claims{
		UserID:     userID,
		OperatorID: operatorID,
		RoleID:     roleID,
	}, nil
}

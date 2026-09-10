package paseto

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"time"

	"befriend/config"

	"aidanwoods.dev/go-paseto"
)

// Claims identify one signed-in device of one user.
type Claims struct {
	UserID   string `json:"user_id"`
	DeviceID string `json:"device_id"`
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

// GenerateTokens generates access and refresh tokens for a user's device using PASETO v4
func GenerateTokens(data Claims) (string, string, error) {
	now := time.Now()

	accessToken := paseto.NewToken()
	accessToken.SetString("user_id", data.UserID)
	accessToken.SetString("device_id", data.DeviceID)
	accessToken.SetIssuer(config.Config.System.AppName)
	accessToken.SetIssuedAt(now)
	accessToken.SetNotBefore(now)
	accessToken.SetExpiration(now.Add(time.Duration(config.Config.PASETO.AccessExpiryMin) * time.Minute))

	refreshToken := paseto.NewToken()
	refreshToken.SetString("user_id", data.UserID)
	refreshToken.SetString("device_id", data.DeviceID)
	refreshToken.SetIssuer(config.Config.System.AppName)
	refreshToken.SetIssuedAt(now)
	refreshToken.SetNotBefore(now)
	refreshToken.SetExpiration(now.Add(time.Duration(config.Config.PASETO.RefreshExpiryDay) * 24 * time.Hour))

	encryptedAccess := accessToken.V4Encrypt(getSymmetricKey(config.Config.PASETO.AccessSecret), nil)
	encryptedRefresh := refreshToken.V4Encrypt(getSymmetricKey(config.Config.PASETO.RefreshSecret), nil)

	return encryptedAccess, encryptedRefresh, nil
}

// ValidateToken validates the token and returns the claims
func ValidateToken(tokenString string, secret string) (*Claims, error) {
	parser := paseto.NewParser()
	parser.AddRule(paseto.NotExpired())
	parser.AddRule(paseto.ValidAt(time.Now()))

	token, err := parser.ParseV4Local(getSymmetricKey(secret), tokenString, nil)
	if err != nil {
		return nil, err
	}

	userID, err := token.GetString("user_id")
	if err != nil || userID == "" {
		return nil, errors.New("invalid token: missing user_id")
	}

	deviceID, err := token.GetString("device_id")
	if err != nil || deviceID == "" {
		return nil, errors.New("invalid token: missing device_id")
	}

	return &Claims{UserID: userID, DeviceID: deviceID}, nil
}

// HashToken returns the sha256 hex digest stored instead of the raw refresh token.
func HashToken(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:])
}

package provider

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"strings"
)

// DevelopmentSMS is installed only through Identity's environment-validated
// config capability. It never sends SMS for the one explicitly allowed number.
// A signed opaque delivery reference survives restarts without storing the code.
type DevelopmentSMS struct {
	phone, code string
	key         []byte
	fallback    SMS
}

const developmentPrefix = "flow-dev-v1."

func NewDevelopmentSMS(phone, code string, key []byte, fallback SMS) *DevelopmentSMS {
	return &DevelopmentSMS{phone: phone, code: code, key: append([]byte(nil), key...), fallback: fallback}
}

func (d *DevelopmentSMS) signature(nonce string) []byte {
	mac := hmac.New(sha256.New, d.key)
	_, _ = mac.Write([]byte("flow/development-sms/v1\x00" + d.phone + "\x00" + d.code + "\x00" + nonce))
	return mac.Sum(nil)
}

func (d *DevelopmentSMS) Start(ctx context.Context, phone string) (string, error) {
	if err := ctx.Err(); err != nil {
		return "", ErrUnavailable
	}
	if phone != d.phone {
		if d.fallback != nil {
			return d.fallback.Start(ctx, phone)
		}
		return "", ErrUnavailable
	}
	var random [16]byte
	if _, err := rand.Read(random[:]); err != nil {
		return "", ErrUnavailable
	}
	nonce := hex.EncodeToString(random[:])
	return developmentPrefix + nonce + "." + hex.EncodeToString(d.signature(nonce)), nil
}

func (d *DevelopmentSMS) Check(ctx context.Context, reference, code string) (bool, error) {
	if err := ctx.Err(); err != nil {
		return false, ErrUnavailable
	}
	if !strings.HasPrefix(reference, developmentPrefix) {
		if d.fallback != nil {
			return d.fallback.Check(ctx, reference, code)
		}
		return false, ErrRejected
	}
	parts := strings.Split(strings.TrimPrefix(reference, developmentPrefix), ".")
	if len(parts) != 2 || len(parts[0]) != 32 {
		return false, ErrRejected
	}
	nonce, err := hex.DecodeString(parts[0])
	if err != nil || len(nonce) != 16 {
		return false, ErrRejected
	}
	signature, err := hex.DecodeString(parts[1])
	if err != nil || !hmac.Equal(signature, d.signature(parts[0])) {
		return false, ErrRejected
	}
	return subtle.ConstantTimeCompare([]byte(code), []byte(d.code)) == 1, nil
}

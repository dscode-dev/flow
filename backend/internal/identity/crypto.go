package identity

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"net"
	"strings"

	"github.com/google/uuid"
)

func newID() string         { return uuid.Must(uuid.NewV7()).String() }
func validID(v string) bool { _, e := uuid.Parse(v); return e == nil && len(v) == 36 }
func secret() string {
	var b [32]byte
	if _, e := rand.Read(b[:]); e != nil {
		panic("secure random unavailable")
	}
	return base64.RawURLEncoding.EncodeToString(b[:])
}
func digest(v string) []byte { h := sha256.Sum256([]byte(v)); return h[:] }
func (c Config) reference(kind, value string) string {
	h := hmac.New(sha256.New, c.HMACKey)
	_, _ = h.Write([]byte(kind + ":" + value))
	return hex.EncodeToString(h.Sum(nil))
}

// Usa apenas RemoteAddr, nunca cabeçalhos encaminhados pelo cliente. IPv6 é /64.
func (c Config) Origin(remoteAddr string) string {
	host, _, err := net.SplitHostPort(remoteAddr)
	if err != nil {
		host = remoteAddr
	}
	ip := net.ParseIP(host)
	if ip == nil {
		return c.reference("origin", "unknown")
	}
	if ip.To4() == nil {
		ip = ip.Mask(net.CIDRMask(64, 128))
	}
	return c.reference("origin", ip.String())
}
func parseRefresh(raw string) (id, credential string, ok bool) {
	if !strings.HasPrefix(raw, "fr_") || len(raw) > 128 {
		return "", "", false
	}
	parts := strings.Split(strings.TrimPrefix(raw, "fr_"), ".")
	if len(parts) != 2 || !validID(parts[0]) {
		return "", "", false
	}
	b, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil || len(b) != 32 {
		return "", "", false
	}
	return parts[0], parts[1], true
}

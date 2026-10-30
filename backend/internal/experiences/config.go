package experiences

import (
	"crypto/hmac"
	"crypto/sha256"
	"fmt"
	"strconv"
)

type Config struct {
	CreateDaily, PublishDaily, UploadDaily, MaxDrafts int
	CursorKey                                         []byte
}

func ParseConfig(get func(string) string, key []byte) (Config, error) {
	c := Config{}
	for _, p := range []struct {
		k   string
		def int
		dst *int
	}{{"EXPERIENCES_CREATE_DAILY", 20, &c.CreateDaily}, {"EXPERIENCES_PUBLISH_DAILY", 20, &c.PublishDaily}, {"EXPERIENCES_UPLOAD_DAILY", 30, &c.UploadDaily}, {"EXPERIENCES_MAX_DRAFTS", 50, &c.MaxDrafts}} {
		n := p.def
		if v := get(p.k); v != "" {
			var e error
			n, e = strconv.Atoi(v)
			if e != nil {
				return c, fmt.Errorf("%s inválido", p.k)
			}
		}
		if n < 1 || n > 10000 {
			return c, fmt.Errorf("%s inválido", p.k)
		}
		*p.dst = n
	}
	if len(key) != 32 {
		return c, fmt.Errorf("chave de cursor inválida")
	}
	mac := hmac.New(sha256.New, key)
	mac.Write([]byte("flow.experiences.cursor.v1"))
	c.CursorKey = mac.Sum(nil)
	return c, nil
}

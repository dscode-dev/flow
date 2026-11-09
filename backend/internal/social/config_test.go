package social

import (
	"bytes"
	"testing"
)

func TestConfigAndCursorBoundary(t *testing.T) {
	key := bytes.Repeat([]byte{3}, 32)
	c, e := ParseConfig(func(string) string { return "" }, key)
	if e != nil || c.BodyLimit != 3000 || c.MediaLimit != 4 || bytes.Equal(c.Key, key) {
		t.Fatal("defaults/domain key")
	}
	for _, k := range []string{"SOCIAL_BODY_LIMIT", "SOCIAL_MEDIA_LIMIT", "SOCIAL_MUTATION_MINUTE", "SOCIAL_EDIT_HOURS"} {
		if _, e := ParseConfig(func(name string) string {
			if name == k {
				return "0"
			}
			return ""
		}, key); e == nil {
			t.Fatal(k)
		}
	}
	s := &Service{config: c}
	token := s.sign(map[string]string{"purpose": "test"})
	var v map[string]string
	if !s.verify(token, &v) || s.verify(token+"x", &v) || s.verify("bad", &v) {
		t.Fatal("signed capability")
	}
	if _, e := ParseConfig(func(string) string { return "" }, []byte("short")); e == nil {
		t.Fatal("weak key")
	}
}

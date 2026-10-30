package media

import (
	"bytes"
	"image"
	"image/png"
	"strings"
	"testing"
)

func TestSanitizeAndConfig(t *testing.T) {
	var raw bytes.Buffer
	if e := png.Encode(&raw, image.NewNRGBA(image.Rect(0, 0, 2, 3))); e != nil {
		t.Fatal(e)
	}
	b, w, h, e := sanitize(append(raw.Bytes(), []byte("untrusted trailer")...), "image/png")
	if e != nil || w != 2 || h != 3 || bytes.Contains(b, []byte("untrusted trailer")) {
		t.Fatal("reencode", e)
	}
	if _, _, _, e = sanitize(raw.Bytes(), "image/jpeg"); e == nil {
		t.Fatal("MIME spoof")
	}
	if _, _, _, e = sanitize([]byte("<svg></svg>"), "image/png"); e == nil {
		t.Fatal("SVG")
	}
	get := func(k string) string {
		return map[string]string{"MEDIA_S3_ENDPOINT": "http://localhost:8333", "MEDIA_S3_REGION": "us-east-1", "MEDIA_S3_BUCKET": "covers", "MEDIA_S3_ACCESS_KEY": "fixture", "MEDIA_S3_SECRET_KEY": "fixture", "FLOW_ENV": "production"}[k]
	}
	if _, e := ParseStorageConfig(get); e == nil {
		t.Fatal("production HTTP")
	}
	if _, e := ParseStorageConfig(func(string) string { return "" }); e != nil {
		t.Fatal(e)
	}
	if _, e := ParseStorageConfig(func(k string) string {
		if strings.HasSuffix(k, "BUCKET") {
			return "covers"
		}
		return ""
	}); e == nil {
		t.Fatal("partial config")
	}
}

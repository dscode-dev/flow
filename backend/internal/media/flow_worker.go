package media

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"flow.local/backend/internal/platform/database"
	"flow.local/backend/internal/platform/database/dbgen"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
)

// Limited stdout/stderr: hostile metadata and ffmpeg diagnostics must never grow
// memory without a bound or escape to logs. Only local files are passed to tools.
type cappedBuffer struct{ bytes.Buffer }

func (b *cappedBuffer) Write(p []byte) (int, error) {
	if b.Len()+len(p) > 1024*1024 {
		return 0, ErrInvalid
	}
	return b.Buffer.Write(p)
}
func tool(ctx context.Context, name string, args ...string) ([]byte, error) {
	cmd := exec.CommandContext(ctx, name, args...)
	var out, errout cappedBuffer
	cmd.Stdout = &out
	cmd.Stderr = &errout
	cmd.WaitDelay = 2 * time.Second
	if e := cmd.Run(); e != nil {
		return nil, ErrInvalid
	}
	return out.Bytes(), nil
}

type videoProbe struct {
	Streams []struct {
		CodecType string `json:"codec_type"`
		Width     int    `json:"width"`
		Height    int    `json:"height"`
	} `json:"streams"`
	Format struct {
		Duration string `json:"duration"`
		Name     string `json:"format_name"`
	} `json:"format"`
}

func probe(ctx context.Context, path string, maxDimension int) (int, int, float64, error) {
	b, e := tool(ctx, "ffprobe", "-v", "error", "-max_alloc", "67108864", "-protocol_whitelist", "file,pipe", "-show_entries", "stream=codec_type,width,height:format=duration,format_name", "-of", "json", path)
	if e != nil {
		return 0, 0, 0, e
	}
	var p videoProbe
	if json.Unmarshal(b, &p) != nil {
		return 0, 0, 0, ErrInvalid
	}
	duration, e := strconv.ParseFloat(p.Format.Duration, 64)
	if e != nil || math.IsNaN(duration) || math.IsInf(duration, 0) || duration <= 0 || duration > 15 || !strings.Contains(p.Format.Name, "mp4") || len(p.Streams) > 2 {
		return 0, 0, 0, ErrInvalid
	}
	width, height, videos := 0, 0, 0
	for _, st := range p.Streams {
		switch st.CodecType {
		case "video":
			videos++
			width, height = st.Width, st.Height
		case "audio":
		default:
			return 0, 0, 0, ErrInvalid
		}
	}
	if videos != 1 || width < 1 || height < 1 || width > maxDimension || height > maxDimension {
		return 0, 0, 0, ErrInvalid
	}
	return width, height, duration, nil
}

type processedFlow struct {
	data, poster  []byte
	width, height int
	duration      *int32
}

func processFlow(ctx context.Context, u dbgen.MediaFlowAsset, raw []byte, c FlowConfig) (processedFlow, error) {
	var out processedFlow
	if strings.HasPrefix(u.ContentType, "image/") {
		b, w, h, e := sanitize(raw, u.ContentType)
		if e != nil || w > c.MaxDimension || h > c.MaxDimension {
			return out, ErrInvalid
		}
		out.data = b
		out.width = w
		out.height = h
		return out, nil
	}
	dir, e := os.MkdirTemp("", "flow-transcode-")
	if e != nil {
		return out, ErrUnavailable
	}
	defer os.RemoveAll(dir)
	source := filepath.Join(dir, "source.mov")
	video := filepath.Join(dir, "ready.mp4")
	poster := filepath.Join(dir, "poster.jpg")
	if e = os.WriteFile(source, raw, 0600); e != nil {
		return out, ErrUnavailable
	}
	if _, _, _, e = probe(ctx, source, c.MaxDimension); e != nil {
		return out, e
	}
	// Decode the actual stream, limit work to 16s, then reject output >15s. -t 15
	// would silently accept an overlong source with misleading container duration.
	_, e = tool(ctx, "ffmpeg", "-nostdin", "-v", "error", "-max_alloc", "67108864", "-threads", "1", "-filter_threads", "1", "-protocol_whitelist", "file,pipe", "-i", source, "-map", "0:v:0", "-map", "0:a:0?", "-t", "16", "-vf", "scale=w='min(1280,iw)':h='min(1280,ih)':force_original_aspect_ratio=decrease:force_divisible_by=2", "-r", "30", "-c:v", "libx264", "-threads", "1", "-preset", "veryfast", "-crf", "25", "-maxrate", "2500k", "-bufsize", "5000k", "-pix_fmt", "yuv420p", "-c:a", "aac", "-ac", "2", "-b:a", "96k", "-map_metadata", "-1", "-map_chapters", "-1", "-movflags", "+faststart", "-fs", strconv.FormatInt(c.MaxBytes, 10), "-y", video)
	if e != nil {
		return out, e
	}
	w, h, duration, e := probe(ctx, video, 1280)
	if e != nil {
		return out, e
	}
	_, e = tool(ctx, "ffmpeg", "-nostdin", "-v", "error", "-max_alloc", "67108864", "-threads", "1", "-filter_threads", "1", "-protocol_whitelist", "file,pipe", "-i", video, "-map", "0:v:0", "-frames:v", "1", "-vf", "scale=512:512:force_original_aspect_ratio=decrease", "-threads", "1", "-map_metadata", "-1", "-y", poster)
	if e != nil {
		return out, e
	}
	out.data, e = readLocal(video, c.MaxBytes)
	if e != nil {
		return out, e
	}
	out.poster, e = readLocal(poster, MaxBytes)
	if e != nil {
		return out, e
	}
	out.poster, _, _, e = sanitize(out.poster, "image/jpeg")
	if e != nil {
		return out, e
	}
	ms := int32(math.Round(duration * 1000))
	if ms < 1 || ms > 15000 {
		return out, ErrInvalid
	}
	out.width = w
	out.height = h
	out.duration = &ms
	return out, nil
}
func readLocal(path string, max int64) ([]byte, error) {
	f, e := os.Open(path)
	if e != nil {
		return nil, ErrInvalid
	}
	defer f.Close()
	b, e := io.ReadAll(io.LimitReader(f, max+1))
	if e != nil || len(b) == 0 || int64(len(b)) > max {
		return nil, ErrInvalid
	}
	return b, nil
}

// ProcessFlowNext claims one durable job. Multiple workers serialize claims via
// SKIP LOCKED and lease fencing. HTTP confirmation never probes/transcodes.
func (s *Service) ProcessFlowNext(ctx context.Context) (bool, error) {
	q := dbgen.New(s.pool)
	u, e := q.ClaimFlowAsset(ctx, newID())
	if errors.Is(e, pgx.ErrNoRows) {
		return false, nil
	}
	if e != nil {
		return false, e
	}
	task, cancel := context.WithTimeout(ctx, s.flow.Timeout)
	defer cancel()
	raw, ct, e := s.storage.read(task, u.StagingKey, s.flow.MaxBytes)
	var out processedFlow
	if u.Attempts > 3 {
		e = ErrInvalid
	}
	if e == nil {
		if ct != u.ContentType || int64(len(raw)) != u.SizeBytes {
			e = ErrInvalid
		} else {
			out, e = processFlow(task, u, raw, s.flow)
		}
	}
	if e != nil {
		code := "processing_failed"
		if errors.Is(e, ErrInvalid) {
			code = "invalid_media"
		}
		done, c := context.WithTimeout(ctx, 5*time.Second)
		defer c()
		return true, q.FailFlowAsset(done, dbgen.FailFlowAssetParams{ID: u.ID, LeaseID: u.LeaseID, FailureCode: pgtype.Text{String: code, Valid: true}})
	}
	e = database.InTransaction(task, s.pool, func(tx pgx.Tx) error {
		locked, e := dbgen.New(tx).LockFlowAsset(task, u.ID)
		if e != nil {
			return e
		}
		if locked.Status != "PROCESSING" || locked.LeaseID != u.LeaseID || !locked.LeaseUntil.Time.After(time.Now()) {
			return nil
		}
		outCT := u.ContentType
		if out.duration != nil {
			outCT = "video/mp4"
		}
		if e = s.storage.write(task, u.ObjectKey, outCT, out.data); e != nil {
			return e
		}
		if len(out.poster) > 0 {
			if e = s.storage.write(task, u.PosterKey, "image/jpeg", out.poster); e != nil {
				return e
			}
		}
		hash := sha256.Sum256(out.data)
		duration := pgtype.Int4{}
		if out.duration != nil {
			duration = pgtype.Int4{Int32: *out.duration, Valid: true}
		}
		_, e = dbgen.New(tx).ReadyFlowAsset(task, dbgen.ReadyFlowAssetParams{ID: u.ID, LeaseID: u.LeaseID, Width: pgtype.Int4{Int32: int32(out.width), Valid: true}, Height: pgtype.Int4{Int32: int32(out.height), Valid: true}, DurationMs: duration, VerifiedSize: pgtype.Int8{Int64: int64(len(out.data)), Valid: true}, Sha256: pgtype.Text{String: hex.EncodeToString(hash[:]), Valid: true}})
		if e != nil {
			return e
		}
		return flowAudit(task, dbgen.New(tx), u, "flow.media.ready", "worker")
	})
	return true, e
}

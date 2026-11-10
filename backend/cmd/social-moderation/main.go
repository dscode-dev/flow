// Restricted operator tool; never exposed by the API router.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"flow.local/backend/internal/social"
	"fmt"
	"github.com/jackc/pgx/v5/pgxpool"
	"os"
	"time"
)

func run() error {
	operator := flag.String("operator", "", "identidade operacional atribuível")
	caseID := flag.String("case", "", "caso aprovado")
	action := flag.String("action", "", "chat-messages/hide-message/show-message/delete-message/space/hide-space/show-space/reports/post/posts/hide-post/show-post/delete-post/hide-comment/show-comment/restrict-user/restore-user/resolve-report")
	target := flag.String("target", "", "UUID do alvo; posts usa autor")
	flag.Parse()
	dsn := os.Getenv("SOCIAL_MODERATION_DATABASE_URL")
	if dsn == "" {
		return fmt.Errorf("credencial operacional separada obrigatória")
	}
	ctx, c := context.WithTimeout(context.Background(), 10*time.Second)
	defer c()
	p, e := pgxpool.New(ctx, dsn)
	if e != nil {
		return fmt.Errorf("banco operacional indisponível")
	}
	defer p.Close()
	out, e := social.Operate(ctx, p, *operator, *caseID, *action, *target)
	if e != nil {
		return fmt.Errorf("ação operacional recusada")
	}
	return json.NewEncoder(os.Stdout).Encode(out)
}
func main() {
	if e := run(); e != nil {
		fmt.Fprintln(os.Stderr, e)
		os.Exit(1)
	}
}

package main

import (
	"net/http"
	"os"
	"time"
)

func main() {
	if len(os.Args) != 2 {
		os.Exit(2)
	}
	c := http.Client{Timeout: 4 * time.Second}
	r, e := c.Get(os.Args[1])
	if e != nil {
		os.Exit(1)
	}
	_ = r.Body.Close()
	if r.StatusCode != http.StatusOK {
		os.Exit(1)
	}
}

// Command lunar-core runs the local-first SQLite + HTTP API daemon for the Lunar macOS app.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"lunar/core/internal/api"
	"lunar/core/internal/store"
)

func defaultDBPath() (string, error) {
	configDir, err := os.UserConfigDir()
	if err != nil {
		return "", fmt.Errorf("resolve user config dir: %w", err)
	}
	return filepath.Join(configDir, "Lunar", "lunar.db"), nil
}

func run() error {
	addr := flag.String("addr", "127.0.0.1:0", "listen address (host:port)")
	dbFlag := flag.String("db", "", "path to SQLite database file")
	flag.Parse()

	dbPath := *dbFlag
	if dbPath == "" {
		var err error
		dbPath, err = defaultDBPath()
		if err != nil {
			return err
		}
	}

	if dbPath != ":memory:" {
		if err := os.MkdirAll(filepath.Dir(dbPath), 0o755); err != nil {
			return fmt.Errorf("create db directory: %w", err)
		}
	}

	s, err := store.Open(dbPath)
	if err != nil {
		return fmt.Errorf("open store: %w", err)
	}
	defer s.Close()

	if err := s.SeedIfEmpty(); err != nil {
		return fmt.Errorf("seed starter data: %w", err)
	}

	ln, err := net.Listen("tcp", *addr)
	if err != nil {
		return fmt.Errorf("listen %s: %w", *addr, err)
	}

	httpSrv := &http.Server{
		Handler:           api.NewServer(s).Handler(),
		ReadHeaderTimeout: 5 * time.Second,
	}

	// Emit bound address so the parent SwiftUI app can discover ephemeral ports immediately.
	fmt.Printf("LUNAR_CORE_ADDR=%s\n", ln.Addr().String())
	_ = os.Stdout.Sync()

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		_ = httpSrv.Shutdown(shutdownCtx)
	}()

	if err := httpSrv.Serve(ln); err != nil && !errors.Is(err, http.ErrServerClosed) {
		return fmt.Errorf("serve http: %w", err)
	}
	return nil
}

func main() {
	if err := run(); err != nil {
		log.Fatalf("lunar-core: %v", err)
	}
}

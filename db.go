package main

import (
	"context"
	"fmt"
	"log"
	"net"
	"os"
	"strconv"
	"time"

	"cloud.google.com/go/cloudsqlconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

func connectDB(ctx context.Context) (*pgxpool.Pool, error) {
	dbUser := os.Getenv("DB_USER")
	dbPassword := os.Getenv("DB_PASSWORD")
	dbName := os.Getenv("DB_NAME")
	instanceConnectionName := os.Getenv("INSTANCE_CONNECTION_NAME")
	usePrivate := os.Getenv("PRIVATE_IP")

	if dbUser == "" || dbPassword == "" || dbName == "" || instanceConnectionName == "" {
		return nil, fmt.Errorf("missing DB envs: DB_USER/DB_PASSWORD/DB_NAME/INSTANCE_CONNECTION_NAME")
	}

	dsn := fmt.Sprintf("user=%s password=%s database=%s sslmode=disable", dbUser, dbPassword, dbName)

	var opts []cloudsqlconn.Option
	if usePrivate != "" && usePrivate != "false" && usePrivate != "0" {
		opts = append(opts, cloudsqlconn.WithDefaultDialOptions(cloudsqlconn.WithPrivateIP()))
	}
	dialer, err := cloudsqlconn.NewDialer(ctx, opts...)
	if err != nil {
		return nil, fmt.Errorf("cloudsqlconn.NewDialer: %w", err)
	}

	cfg, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		return nil, fmt.Errorf("pgxpool.ParseConfig: %w", err)
	}
	cfg.ConnConfig.DialFunc = func(ctx context.Context, network, addr string) (net.Conn, error) {
		return dialer.Dial(ctx, instanceConnectionName)
	}

	// Reasonable pool sizing knobs
	maxConns := parseInt(os.Getenv("PG_MAX_CONNS"), 10)
	minConns := parseInt(os.Getenv("PG_MIN_CONNS"), 0)
	maxIdle := parseDuration(os.Getenv("PG_MAX_CONN_IDLE"), 10*time.Minute)
	maxLife := parseDuration(os.Getenv("PG_MAX_CONN_LIFE"), 1*time.Hour)

	cfg.MaxConns = int32(maxConns)
	cfg.MinConns = int32(minConns)
	cfg.MaxConnIdleTime = maxIdle
	cfg.MaxConnLifetime = maxLife

	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return nil, fmt.Errorf("pgxpool.NewWithConfig: %w", err)
	}
	if err := pool.Ping(ctx); err != nil {
		return nil, fmt.Errorf("db ping: %w", err)
	}
	log.Println("CONNECTED TO DATABASE")
	return pool, nil
}

func parseInt(s string, def int) int {
	if s == "" {
		return def
	}
	i, err := strconv.Atoi(s)
	if err != nil {
		return def
	}
	return i
}

func parseDuration(s string, def time.Duration) time.Duration {
	if s == "" {
		return def
	}
	d, err := time.ParseDuration(s)
	if err != nil {
		return def
	}
	return d
}

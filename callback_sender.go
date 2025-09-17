package main

import (
	"bytes"
	"context"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"time"

	"github.com/hashicorp/go-retryablehttp"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

const RequestTimeout = 10 * time.Second

// Error classification for Pub/Sub ack semantics
type transientError struct{ err error }

func (e transientError) Error() string { return e.err.Error() }
func IsTransient(err error) bool {
	var te transientError
	return errors.As(err, &te)
}
func transient(err error) error { return transientError{err: err} }

type InvalidMessageError struct{ msg string }

func (e *InvalidMessageError) Error() string { return e.msg }

// Sender

type CallbackSender struct {
	httpClient *retryablehttp.Client
	dbPool     *pgxpool.Pool
}

type CallbackConfig struct {
	URL     string                 `db:"url"`
	Method  string                 `db:"method"`
	Headers map[string]interface{} `db:"headers"`
	Enabled *bool                  `db:"is_enabled"`
}

func NewCallbackSender(dbPool *pgxpool.Pool) *CallbackSender {
	retryClient := retryablehttp.NewClient()
	retryClient.RetryMax = 3
	retryClient.RetryWaitMin = 150 * time.Millisecond
	retryClient.RetryWaitMax = 1 * time.Second
	retryClient.HTTPClient.Timeout = RequestTimeout

	return &CallbackSender{
		httpClient: retryClient,
		dbPool:     dbPool,
	}
}

// Handle receives parsed payload and fan-outs to per-client callbacks.
// Returns nil on success.
// Returns *InvalidMessageError (permanent) for bad payloads.
// Returns transientError for retryable downstream/DB issues.
func (cs *CallbackSender) Handle(ctx context.Context, payload map[string]any) error {
	deviceID, ok := readStringAny(payload, "deviceId", "device_id", "deviceID")
	if !ok || deviceID == "" {
		return &InvalidMessageError{msg: "Missing deviceId"}
	}

	clientID, err := cs.getClientIDByDeviceId(ctx, deviceID)
	if err != nil {
		// Unknown device is permanent (ack & drop)
		if errors.Is(err, pgx.ErrNoRows) {
			return &InvalidMessageError{msg: fmt.Sprintf("device %s not found", deviceID)}
		}
		// Other DB errors → transient
		return transient(fmt.Errorf("getClientID: %w", err))
	}

	configs, err := cs.getCallbackConfigsByClientId(ctx, clientID)
	if err != nil {
		return transient(fmt.Errorf("getCallbackConfigs: %w", err))
	}
	if len(configs) == 0 {
		// No callbacks configured → permanent OK
		log.Printf("client %d has no enabled callback_configs; skipping", clientID)
		return nil
	}

	// Send all callbacks; classify outcomes
	var transientCount int
	for _, cfg := range configs {
		if cfg.Enabled != nil && !*cfg.Enabled {
			continue
		}
		if cfg.URL == "" {
			continue
		}

		headers := toStringMap(cfg.Headers)
		status, body, err := cs.SendCallback(ctx, cfg.URL, cfg.Method, headers, payload)
		if err != nil {
			// Network/timeouts treated as transient
			log.Printf("callback error url=%s err=%v", cfg.URL, err)
			transientCount++
			continue
		}
		if isRetryableStatus(status) {
			log.Printf("callback retryable status=%d url=%s body=%q", status, cfg.URL, truncate(body, 400))
			transientCount++
			continue
		}
		if status >= 400 {
			// Permanent failure on 4xx (except 408/429) → ack
			log.Printf("callback permanent status=%d url=%s body=%q", status, cfg.URL, truncate(body, 400))
			continue
		}
		// 2xx/3xx → ok
	}

	if transientCount > 0 {
		return transient(fmt.Errorf("%d transient callback failures", transientCount))
	}
	return nil
}

// SendCallback executes one HTTP request with retries/timeouts.
// Returns (statusCode, respBody, error).
func (cs *CallbackSender) SendCallback(ctx context.Context, url, method string, headers map[string]string, body map[string]any) (int, string, error) {
	if method == "" {
		method = http.MethodPost
	}
	jsonBytes, err := json.Marshal(body)
	if err != nil {
		return 0, "", fmt.Errorf("marshal body: %w", err)
	}

	req, err := retryablehttp.NewRequest(method, url, bytes.NewReader(jsonBytes))
	if err != nil {
		return 0, "", fmt.Errorf("new request: %w", err)
	}
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	if req.Header.Get("Content-Type") == "" {
		req.Header.Set("Content-Type", "application/json")
	}

	// Mask auth in logs
	logHeaders := make(map[string]string, len(headers))
	for k, v := range headers {
		if equalFold(k, "Authorization") {
			logHeaders[k] = "hidden"
		} else {
			logHeaders[k] = v
		}
	}

	req = req.WithContext(ctx)
	resp, err := cs.httpClient.Do(req)
	if err != nil {
		// Network / timeout → transient
		return 0, "", err
	}
	defer resp.Body.Close()

	b, _ := io.ReadAll(resp.Body)
	// Optional: log request/response
	// log.Printf("callback url=%s method=%s status=%d headers=%+v body=%s", url, method, resp.StatusCode, logHeaders, truncate(string(jsonBytes), 400))

	return resp.StatusCode, string(b), nil
}

// DB helpers

func (cs *CallbackSender) getClientIDByDeviceId(ctx context.Context, deviceID string) (int64, error) {
	b, err := hexToBytes(deviceID)
	if err != nil {
		return 0, fmt.Errorf("invalid device ID hex: %w", err)
	}
	var clientID int64
	const q = `SELECT client_id FROM devices WHERE device_id = $1`
	err = cs.dbPool.QueryRow(ctx, q, b).Scan(&clientID)
	if err != nil {
		return 0, err
	}
	return clientID, nil
}

func (cs *CallbackSender) getCallbackConfigsByClientId(ctx context.Context, clientID int64) ([]CallbackConfig, error) {
	const q = `SELECT url, method, headers, is_enabled
	           FROM callback_configs
	           WHERE client_id = $1`
	rows, err := cs.dbPool.Query(ctx, q, clientID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var res []CallbackConfig
	for rows.Next() {
		var c CallbackConfig
		if err := rows.Scan(&c.URL, &c.Method, &c.Headers, &c.Enabled); err != nil {
			return nil, err
		}
		res = append(res, c)
	}
	return res, rows.Err()
}

// utils

func toStringMap(m map[string]any) map[string]string {
	out := make(map[string]string, len(m))
	for k, v := range m {
		if s, ok := v.(string); ok {
			out[k] = s
		}
	}
	return out
}

func isRetryableStatus(code int) bool {
	// Retry: 408 Request Timeout, 429 Too Many Requests, and 5xx
	return code == 408 || code == 429 || (code >= 500 && code <= 599)
}

func truncate(s string, n int) string {
	if n <= 0 || len(s) <= n {
		return s
	}
	return s[:n] + "…"
}

func readStringAny(m map[string]any, keys ...string) (string, bool) {
	for _, k := range keys {
		if v, ok := m[k]; ok {
			if s, ok := v.(string); ok && s != "" {
				return s, true
			}
		}
	}
	return "", false
}

func hexToBytes(hexStr string) ([]byte, error) {
	if hexStr == "" {
		return nil, fmt.Errorf("empty hex")
	}
	return hex.DecodeString(removeHexSeparators(hexStr))
}

func removeHexSeparators(s string) string {
	// remove ':', '-', spaces if present
	out := make([]byte, 0, len(s))
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c == ':' || c == '-' || c == ' ' {
			continue
		}
		out = append(out, c)
	}
	return string(out)
}

func equalFold(a, b string) bool {
	// minimal allocation-free case-insensitive compare for header keys
	if len(a) != len(b) {
		return false
	}
	for i := 0; i < len(a); i++ {
		aa := a[i]
		bb := b[i]
		if 'A' <= aa && aa <= 'Z' {
			aa += 'a' - 'A'
		}
		if 'A' <= bb && bb <= 'Z' {
			bb += 'a' - 'A'
		}
		if aa != bb {
			return false
		}
	}
	return true
}

func genTraceID() string {
	return fmt.Sprintf("%d", time.Now().UnixNano())
}

package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"time"
)

// Pub/Sub push payload
type pubsubPush struct {
	Message struct {
		Data       string            `json:"data"`
		Attributes map[string]string `json:"attributes"`
	} `json:"message"`
	Subscription string `json:"subscription"`
}

func indexHandler(callbackSender *CallbackSender, w http.ResponseWriter, r *http.Request) {
	start := time.Now()
	trace := genTraceID()

	if r.Method != http.MethodPost {
		http.Error(w, "only POST", http.StatusMethodNotAllowed)
		return
	}

	var envelope pubsubPush
	if err := json.NewDecoder(r.Body).Decode(&envelope); err != nil {
		log.Printf("TRACE %s decode envelope error: %v", trace, err)
		// Bad envelope is permanent → ack (200)
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("Bad Request: invalid Pub/Sub envelope"))
		return
	}

	if envelope.Message.Data == "" {
		log.Printf("TRACE %s no data in Pub/Sub message", trace)
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("Bad Request: empty data"))
		return
	}

	raw, err := base64.StdEncoding.DecodeString(envelope.Message.Data)
	if err != nil {
		log.Printf("TRACE %s base64 error: %v", trace, err)
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("Bad Request: invalid base64 data"))
		return
	}

	var payload map[string]any
	if err := json.Unmarshal(raw, &payload); err != nil {
		log.Printf("TRACE %s payload JSON error: %v; raw=%q", trace, err, string(raw))
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("Bad Request: invalid JSON payload"))
		return
	}

	// Unwrap body if present
	if body, ok := payload["body"]; ok {
		if m, ok := body.(map[string]any); ok {
			payload = m
		} else {
			log.Printf("TRACE %s invalid body wrapper format", trace)
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte("Bad Request: invalid body wrapper"))
			return
		}
	}

	ctx, cancel := context.WithTimeout(r.Context(), 25*time.Second)
	defer cancel()

	// Handle and classify error (transient/permanent)
	err = callbackSender.Handle(ctx, payload)
	if err == nil {
		w.WriteHeader(http.StatusNoContent) // 204 success → ack
		return
	}

	if IsTransient(err) {
		// 5xx → Pub/Sub retries (up to DLQ)
		log.Printf("TRACE %s transient error: %v (retrying)", trace, err)
		http.Error(w, fmt.Sprintf("Transient: %v", err), http.StatusInternalServerError)
		return
	}

	// Permanent → ack to drop
	log.Printf("TRACE %s permanent error: %v (acking)", trace, err)
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte("Permanent error: " + err.Error()))

	_ = start // (left in case you want to log elapsed)
}

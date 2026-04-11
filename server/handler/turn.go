package handler

import (
	"crypto/hmac"
	"crypto/sha1"
	"encoding/base64"
	"net/http"
	"strconv"
	"strings"
	"time"

	"push-server/config"
)

type turnCredentialsResponse struct {
	Enabled    bool     `json:"enabled"`
	URLs       []string `json:"urls"`
	Username   string   `json:"username,omitempty"`
	Credential string   `json:"credential,omitempty"`
	TTLSeconds int      `json:"ttl_seconds,omitempty"`
	Realm      string   `json:"realm,omitempty"`
}

func GetTurnCredentials(cfg *config.Config) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !cfg.TurnEnabled || len(cfg.TurnURLs) == 0 || cfg.TurnSharedSecret == "" {
			writeJSON(w, 200, turnCredentialsResponse{
				Enabled: false,
				URLs:    []string{},
			})
			return
		}

		token := strings.TrimSpace(strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer "))
		if token == "" {
			token = strings.TrimSpace(r.URL.Query().Get("token"))
		}

		sessionID := strings.TrimSpace(r.URL.Query().Get("session_id"))
		if tokenSessionID := extractSessionFromToken(token, cfg.JWTSecret); tokenSessionID != "" {
			if sessionID == "" {
				sessionID = tokenSessionID
			}
		}
		if sessionID == "" {
			errorJSON(w, 400, "需要 session_id")
			return
		}

		role := strings.TrimSpace(r.URL.Query().Get("role"))
		if role == "" {
			role = "client"
		}

		expiresAt := time.Now().Unix() + int64(cfg.TurnTTLSeconds)
		username := strconv.FormatInt(expiresAt, 10) + ":" + sessionID + ":" + role
		hash := hmac.New(sha1.New, []byte(cfg.TurnSharedSecret))
		_, _ = hash.Write([]byte(username))
		credential := base64.StdEncoding.EncodeToString(hash.Sum(nil))

		writeJSON(w, 200, turnCredentialsResponse{
			Enabled:    true,
			URLs:       cfg.TurnURLs,
			Username:   username,
			Credential: credential,
			TTLSeconds: cfg.TurnTTLSeconds,
			Realm:      cfg.TurnRealm,
		})
	}
}

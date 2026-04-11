package config

import (
	"os"
	"strconv"
	"strings"
)

type Config struct {
	Port      int
	DBPath    string
	JWTSecret string
	TurnEnabled      bool
	TurnURLs         []string
	TurnSharedSecret string
	TurnTTLSeconds   int
	TurnRealm        string
}

func Load() *Config {
	port := 18900
	if v := os.Getenv("PORT"); v != "" {
		if p, err := strconv.Atoi(v); err == nil {
			port = p
		}
	}

	dbPath := "data/push_server.db"
	if v := os.Getenv("DB_PATH"); v != "" {
		dbPath = v
	}

	jwtSecret := "your-jwt-secret"
	if v := os.Getenv("JWT_SECRET"); v != "" {
		jwtSecret = v
	}

	turnURLs := []string{}
	if v := os.Getenv("TURN_URLS"); v != "" {
		for _, rawURL := range strings.Split(v, ",") {
			trimmed := strings.TrimSpace(rawURL)
			if trimmed == "" {
				continue
			}
			turnURLs = append(turnURLs, trimmed)
		}
	}

	turnSharedSecret := strings.TrimSpace(os.Getenv("TURN_SHARED_SECRET"))

	turnTTLSeconds := 3600
	if v := os.Getenv("TURN_TTL_SECONDS"); v != "" {
		if ttl, err := strconv.Atoi(v); err == nil && ttl > 0 {
			turnTTLSeconds = ttl
		}
	}

	turnRealm := "your-server.example.com"
	if v := strings.TrimSpace(os.Getenv("TURN_REALM")); v != "" {
		turnRealm = v
	}

	turnEnabled := len(turnURLs) > 0 && turnSharedSecret != ""
	if v := strings.TrimSpace(os.Getenv("TURN_ENABLED")); v != "" {
		normalized := strings.ToLower(v)
		turnEnabled = normalized == "1" || normalized == "true" || normalized == "yes" || normalized == "on"
	}

	return &Config{
		Port:             port,
		DBPath:           dbPath,
		JWTSecret:        jwtSecret,
		TurnEnabled:      turnEnabled,
		TurnURLs:         turnURLs,
		TurnSharedSecret: turnSharedSecret,
		TurnTTLSeconds:   turnTTLSeconds,
		TurnRealm:        turnRealm,
	}
}

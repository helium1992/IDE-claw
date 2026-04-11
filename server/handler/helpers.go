package handler

import (
	"encoding/json"
	"net/http"
	"strings"

	"push-server/config"
)

func writeJSON(w http.ResponseWriter, status int, data interface{}) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(data)
}

func readJSON(r *http.Request, v interface{}) error {
	defer r.Body.Close()
	return json.NewDecoder(r.Body).Decode(v)
}

func errorJSON(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}

// RequireAuth JWT 认证中间件
func RequireAuth(cfg *config.Config, next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		auth := r.Header.Get("Authorization")
		if auth == "" {
			// 也支持 query 参数
			auth = "Bearer " + r.URL.Query().Get("token")
		}

		if !strings.HasPrefix(auth, "Bearer ") {
			errorJSON(w, 401, "需要 Bearer Token")
			return
		}

		token := strings.TrimPrefix(auth, "Bearer ")
		if !validateToken(token, cfg.JWTSecret) {
			errorJSON(w, 401, "Token 无效")
			return
		}

		next(w, r)
	}
}

// 简单 token 验证（HMAC-SHA256 JWT 或静态 token）
func validateToken(token, secret string) bool {
	// 简化方案：直接用静态 token 比对
	// 生产环境应改为完整 JWT 验证
	if token == secret {
		return true
	}
	// 也接受 "session_id:secret" 格式
	parts := strings.SplitN(token, ":", 2)
	if len(parts) == 2 && parts[1] == secret {
		return true
	}
	return false
}

func extractSessionFromToken(token, secret string) string {
	parts := strings.SplitN(token, ":", 2)
	if len(parts) == 2 && parts[1] == secret {
		return parts[0]
	}
	return ""
}

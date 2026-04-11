package handler

import (
	"net/http"

	"push-server/config"
	"push-server/store"
)

// Health 健康检查
func Health(cfg *config.Config) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 200, map[string]interface{}{
			"status":  "ok",
			"service": "push-server",
			"port":    cfg.Port,
		})
	}
}

// AuthToken 获取认证 Token
func AuthToken(db *store.DB, cfg *config.Config) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			SessionID string `json:"session_id"`
			Name      string `json:"name"`
			Secret    string `json:"secret"`
		}
		if err := readJSON(r, &req); err != nil {
			errorJSON(w, 400, "无效的请求体")
			return
		}
		if req.Secret != cfg.JWTSecret {
			errorJSON(w, 401, "密钥错误")
			return
		}
		if req.SessionID == "" {
			errorJSON(w, 400, "需要 session_id")
			return
		}

		session, err := db.GetOrCreateSession(req.SessionID, req.Name)
		if err != nil {
			errorJSON(w, 500, "创建会话失败: "+err.Error())
			return
		}

		// 生成 token: session_id:secret
		token := req.SessionID + ":" + cfg.JWTSecret

		writeJSON(w, 200, map[string]interface{}{
			"token":   token,
			"session": session,
		})
	}
}

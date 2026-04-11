package handler

import (
	"encoding/json"
	"net/http"
	"sync"
	"time"

	"push-server/config"
)

// EndpointInfo 存储PC端的直连端点信息
type EndpointInfo struct {
	SessionID string   `json:"session_id"`
	Endpoints []string `json:"endpoints"`
	LocalIPs  []string `json:"local_ips"`
	PublicIP  string   `json:"public_ip"`
	Port      int      `json:"port"`
	Timestamp string   `json:"timestamp"`
	UpdatedAt time.Time `json:"-"`
}

// EndpointRegistry 端点注册表
var endpointRegistry = struct {
	sync.RWMutex
	m map[string]*EndpointInfo // session_id -> EndpointInfo
}{m: make(map[string]*EndpointInfo)}

// RegisterEndpoint 注册PC端直连端点
func RegisterEndpoint(cfg *config.Config) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var req EndpointInfo
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			errorJSON(w, 400, "无效请求体")
			return
		}
		if req.SessionID == "" {
			errorJSON(w, 400, "session_id 必填")
			return
		}

		req.UpdatedAt = time.Now()
		endpointRegistry.Lock()
		endpointRegistry.m[req.SessionID] = &req
		endpointRegistry.Unlock()

		writeJSON(w, 200, map[string]interface{}{
			"success": true,
			"message": "端点已注册",
		})
	}
}

// GetEndpoint 获取PC端直连端点（手机用来发现电脑IP）
func GetEndpoint(cfg *config.Config) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		sessionID := r.URL.Query().Get("session_id")
		if sessionID == "" {
			errorJSON(w, 400, "session_id 必填")
			return
		}

		endpointRegistry.RLock()
		info := endpointRegistry.m[sessionID]
		endpointRegistry.RUnlock()

		if info == nil {
			writeJSON(w, 200, map[string]interface{}{
				"available": false,
				"message":   "该会话无直连端点",
			})
			return
		}

		// 检查是否过期（5分钟未更新视为离线）
		if time.Since(info.UpdatedAt) > 5*time.Minute {
			writeJSON(w, 200, map[string]interface{}{
				"available": false,
				"message":   "端点已过期",
			})
			return
		}

		writeJSON(w, 200, map[string]interface{}{
			"available": true,
			"endpoints": info.Endpoints,
			"local_ips": info.LocalIPs,
			"public_ip": info.PublicIP,
			"port":      info.Port,
			"timestamp": info.Timestamp,
		})
	}
}

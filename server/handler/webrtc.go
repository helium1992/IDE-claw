package handler

import (
	"encoding/json"
	"net/http"
	"sync"
	"time"

	"push-server/config"
	"push-server/ws"
)

// WebRTC信令消息类型
// offer  - 发起方SDP offer
// answer - 应答方SDP answer
// candidate - ICE candidate

// SignalMessage WebRTC信令消息
type SignalMessage struct {
	Type      string          `json:"type"`      // offer, answer, candidate
	From      string          `json:"from"`      // pc 或 mobile
	SessionID string          `json:"session_id"`
	AttemptID string          `json:"attempt_id,omitempty"`
	Payload   json.RawMessage `json:"payload"`   // SDP或ICE candidate
	Timestamp time.Time       `json:"timestamp"`
}

// 信令缓冲：存储未被对方取走的信令消息
var signalBuffer = struct {
	sync.RWMutex
	m map[string][]SignalMessage // key: session_id:target_role
}{m: make(map[string][]SignalMessage)}

func signalBufferKey(sessionID string, role string, attemptID string) string {
	if attemptID == "" {
		return sessionID + ":" + role
	}
	return sessionID + ":" + role + ":" + attemptID
}

func clearSignalBufferForSession(sessionID string) {
	signalBuffer.Lock()
	defer signalBuffer.Unlock()
	prefix := sessionID + ":"
	for key := range signalBuffer.m {
		if len(key) >= len(prefix) && key[:len(prefix)] == prefix {
			delete(signalBuffer.m, key)
		}
	}
}

// PostSignal 发送WebRTC信令（通过WebSocket实时推送 + HTTP缓冲）
func PostSignal(hub *ws.Hub, cfg *config.Config) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var msg SignalMessage
		if err := json.NewDecoder(r.Body).Decode(&msg); err != nil {
			errorJSON(w, 400, "无效请求体")
			return
		}
		if msg.SessionID == "" || msg.Type == "" || msg.From == "" {
			errorJSON(w, 400, "session_id, type, from 必填")
			return
		}
		msg.Timestamp = time.Now()
		if msg.Type == "offer" && msg.From == "pc" {
			clearSignalBufferForSession(msg.SessionID)
		}

		// 确定目标角色
		targetRole := "mobile"
		if msg.From == "mobile" {
			targetRole = "pc"
		}

		// 通过WebSocket实时推送给对方
		wsMsg := map[string]interface{}{
			"type": "webrtc_signal",
			"data": msg,
		}
		wsMsgBytes, _ := json.Marshal(wsMsg)
		hub.BroadcastToSessionRole(msg.SessionID, targetRole, wsMsgBytes)

		// 同时存入缓冲（防止WebSocket未连接时丢失）
		bufKey := signalBufferKey(msg.SessionID, targetRole, msg.AttemptID)
		signalBuffer.Lock()
		signalBuffer.m[bufKey] = append(signalBuffer.m[bufKey], msg)
		// 限制缓冲大小
		if len(signalBuffer.m[bufKey]) > 50 {
			signalBuffer.m[bufKey] = signalBuffer.m[bufKey][len(signalBuffer.m[bufKey])-50:]
		}
		signalBuffer.Unlock()

		writeJSON(w, 200, map[string]interface{}{
			"success": true,
		})
	}
}

// GetSignals 拉取待接收的WebRTC信令消息
func GetSignals(cfg *config.Config) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		sessionID := r.URL.Query().Get("session_id")
		role := r.URL.Query().Get("role") // 自己的角色
		attemptID := r.URL.Query().Get("attempt_id")
		if sessionID == "" || role == "" {
			errorJSON(w, 400, "session_id, role 必填")
			return
		}

		signalBuffer.Lock()
		var msgs []SignalMessage
		if attemptID != "" {
			bufKey := signalBufferKey(sessionID, role, attemptID)
			msgs = signalBuffer.m[bufKey]
			delete(signalBuffer.m, bufKey)
		} else {
			prefix := sessionID + ":" + role
			for key, buffered := range signalBuffer.m {
				if len(key) >= len(prefix) && key[:len(prefix)] == prefix {
					msgs = append(msgs, buffered...)
					delete(signalBuffer.m, key)
				}
			}
		}
		signalBuffer.Unlock()

		if msgs == nil {
			msgs = []SignalMessage{}
		}

		writeJSON(w, 200, map[string]interface{}{
			"signals": msgs,
		})
	}
}

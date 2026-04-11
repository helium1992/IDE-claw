package handler

import (
	"encoding/json"
	"log"
	"net/http"
	"strings"

	"push-server/config"
	"push-server/store"
	"push-server/ws"

	"github.com/gorilla/websocket"
)

var upgrader = websocket.Upgrader{
	ReadBufferSize:  1024,
	WriteBufferSize: 1024,
	CheckOrigin: func(r *http.Request) bool {
		return true // 允许所有来源
	},
}

// WSHandler WebSocket 连接处理
func WSHandler(hub *ws.Hub, db *store.DB, cfg *config.Config) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		// 从 query 参数获取 token 和 session
		token := r.URL.Query().Get("token")
		sessionID := r.URL.Query().Get("session_id")
		role := r.URL.Query().Get("role")
		if role == "" {
			role = "mobile"
		}

		// 验证 token
		if !validateToken(token, cfg.JWTSecret) {
			errorJSON(w, 401, "WebSocket Token 无效")
			return
		}

		// 如果 token 中包含 session_id，优先使用
		if parts := strings.SplitN(token, ":", 2); len(parts) == 2 {
			if sessionID == "" {
				sessionID = parts[0]
			}
		}

		if sessionID == "" {
			errorJSON(w, 400, "需要 session_id")
			return
		}

		// 升级连接
		conn, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			log.Printf("WebSocket 升级失败: %v", err)
			return
		}

		client := &ws.Client{
			Hub:       hub,
			Conn:      conn,
			Send:      make(chan json.RawMessage, 256),
			SessionID: sessionID,
			Role:      role,
		}

		hub.Register(client)

		// 处理来自客户端的消息
		onMessage := func(c *ws.Client, msg ws.WSMessage) {
			forward := func(targetRole string, outbound ws.WSMessage) {
				payload, err := json.Marshal(outbound)
				if err != nil {
					log.Printf("WebSocket 转发消息序列化失败: %v", err)
					return
				}
				hub.BroadcastToSessionRole(c.SessionID, targetRole, payload)
			}
			switch msg.Type {
			case "ack":
				if msg.MessageID != "" {
					db.AckMessage(msg.MessageID)
				}
			case "command":
				// 手机端通过 WebSocket 发送指令
				var cmdData struct {
					Command string `json:"command"`
					Params  string `json:"params"`
				}
				if err := json.Unmarshal(msg.Data, &cmdData); err == nil {
					// 存储并广播
					log.Printf("📲 收到 WebSocket 指令: %s", cmdData.Command)
				}
			case "remote_frame", "remote_status":
				if c.Role == "pc" {
					forward("mobile", msg)
				}
			case "remote_input":
				if c.Role == "mobile" {
					forward("pc", msg)
				}
			}
		}

		go client.WritePump()
		go client.ReadPump(onMessage)
	}
}

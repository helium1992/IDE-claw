package handler

import (
	"encoding/json"
	"net/http"
	"time"

	"push-server/store"
	"push-server/ws"

	"github.com/google/uuid"
)

// extractDisplayText 从指令参数中提取显示文本
func extractDisplayText(command, params string) string {
	if command == "reply" {
		var p map[string]interface{}
		if err := json.Unmarshal([]byte(params), &p); err == nil {
			if text, ok := p["text"].(string); ok {
				return text
			}
		}
	}
	return "📲 " + command
}

// CreateCommand 手机端发送反向指令
func CreateCommand(db *store.DB, hub *ws.Hub) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			SessionID string `json:"session_id"`
			Command   string `json:"command"`
			Params    string `json:"params"`
		}
		if err := readJSON(r, &req); err != nil {
			errorJSON(w, 400, "无效的请求体")
			return
		}
		if req.SessionID == "" || req.Command == "" {
			errorJSON(w, 400, "session_id 和 command 不能为空")
			return
		}
		if req.Params == "" {
			req.Params = "{}"
		}

		now := time.Now().UTC().Format(time.RFC3339)
		cmdID := uuid.New().String()

		cmd := &store.Command{
			ID:        cmdID,
			SessionID: req.SessionID,
			Command:   req.Command,
			Params:    req.Params,
			Status:    "pending",
			CreatedAt: now,
		}

		if err := db.InsertCommand(cmd); err != nil {
			errorJSON(w, 500, "指令存储失败: "+err.Error())
			return
		}

		// 同时写入 messages 表，使手机刷新后仍能看到自己发的消息
		displayText := extractDisplayText(req.Command, req.Params)
		msg := store.Message{
			ID:        "cmd_" + cmdID,
			SessionID: req.SessionID,
			Content:   displayText,
			MsgType:   "text",
			Sender:    "mobile",
			IsFinal:   true,
			Status:    "delivered",
			CreatedAt: now,
		}
		_ = db.InsertMessage(&msg) // 忽略错误，不影响命令本身

		// 通知 PC 端有新指令
		hub.BroadcastToSession(req.SessionID, map[string]interface{}{
			"type": "command",
			"data": cmd,
		})

		writeJSON(w, 200, map[string]interface{}{
			"success":    true,
			"command_id": cmd.ID,
		})
	}
}

// GetPendingCommands PC端拉取待执行指令
func GetPendingCommands(db *store.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		sessionID := r.URL.Query().Get("session_id")
		if sessionID == "" {
			errorJSON(w, 400, "需要 session_id 参数")
			return
		}

		cmds, err := db.GetPendingCommands(sessionID)
		if err != nil {
			errorJSON(w, 500, "查询指令失败: "+err.Error())
			return
		}
		if cmds == nil {
			cmds = []store.Command{}
		}

		writeJSON(w, 200, map[string]interface{}{
			"commands": cmds,
			"count":    len(cmds),
		})
	}
}

// CommandResult PC端提交指令执行结果
func CommandResult(db *store.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		id := r.PathValue("id")
		if id == "" {
			errorJSON(w, 400, "需要指令 ID")
			return
		}

		var req struct {
			Status string `json:"status"`
			Result string `json:"result"`
		}
		if err := readJSON(r, &req); err != nil {
			errorJSON(w, 400, "无效的请求体")
			return
		}
		if req.Status == "" {
			req.Status = "executed"
		}

		if err := db.UpdateCommandStatus(id, req.Status, req.Result); err != nil {
			errorJSON(w, 500, "更新指令失败: "+err.Error())
			return
		}

		writeJSON(w, 200, map[string]string{"status": req.Status})
	}
}

// WaitCommand PC端长轮询等待新指令
func WaitCommand(db *store.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		sessionID := r.URL.Query().Get("session_id")
		if sessionID == "" {
			errorJSON(w, 400, "需要 session_id 参数")
			return
		}

		timeoutSec := 60
		timeout := time.Duration(timeoutSec) * time.Second

		cmd, err := db.WaitForCommand(sessionID, timeout)
		if err != nil {
			errorJSON(w, 500, "等待指令失败: "+err.Error())
			return
		}

		if cmd == nil {
			writeJSON(w, 200, map[string]interface{}{
				"command": nil,
				"timeout": true,
			})
			return
		}

		writeJSON(w, 200, map[string]interface{}{
			"command": cmd,
			"timeout": false,
		})
	}
}

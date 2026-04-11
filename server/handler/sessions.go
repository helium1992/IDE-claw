package handler

import (
	"net/http"

	"push-server/store"
)

// ListSessions 列出所有会话（含未读数+最新消息）
func ListSessions(db *store.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		sessions, err := db.ListSessionsEnriched()
		if err != nil {
			errorJSON(w, 500, "查询会话失败: "+err.Error())
			return
		}
		if sessions == nil {
			sessions = []store.SessionEnriched{}
		}
		writeJSON(w, 200, map[string]interface{}{
			"sessions": sessions,
			"count":    len(sessions),
		})
	}
}

// MarkSessionRead 标记会话所有消息为已读
func MarkSessionRead(db *store.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			SessionID string `json:"session_id"`
		}
		if err := readJSON(r, &req); err != nil {
			errorJSON(w, 400, "无效的请求体")
			return
		}
		if req.SessionID == "" {
			errorJSON(w, 400, "需要 session_id")
			return
		}
		if err := db.MarkSessionRead(req.SessionID); err != nil {
			errorJSON(w, 500, "标记失败: "+err.Error())
			return
		}
		writeJSON(w, 200, map[string]interface{}{"success": true})
	}
}

// UpdateSessionMeta 更新会话元数据（PC端注册时调用）
func UpdateSessionMeta(db *store.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			SessionID   string `json:"session_id"`
			MachineName string `json:"machine_name"`
			ProjectName string `json:"project_name"`
			IDEType     string `json:"ide_type"`
			DisplayName string `json:"display_name"`
			Description string `json:"description"`
		}
		if err := readJSON(r, &req); err != nil {
			errorJSON(w, 400, "无效的请求体")
			return
		}
		if req.SessionID == "" {
			errorJSON(w, 400, "需要 session_id")
			return
		}

		// 确保 session 存在
		db.GetOrCreateSession(req.SessionID, req.DisplayName)

		if err := db.UpdateSessionMeta(req.SessionID, req.MachineName, req.ProjectName, req.IDEType, req.DisplayName, req.Description); err != nil {
			errorJSON(w, 500, "更新失败: "+err.Error())
			return
		}
		db.TouchSession(req.SessionID)

		writeJSON(w, 200, map[string]interface{}{
			"success": true,
		})
	}
}

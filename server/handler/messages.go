package handler

import (
	"net/http"

	"push-server/store"
)

// GetMessages 手机端拉取历史消息
func GetMessages(db *store.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		sessionID := r.URL.Query().Get("session_id")
		since := r.URL.Query().Get("since")
		if sessionID == "" {
			errorJSON(w, 400, "需要 session_id 参数")
			return
		}
		if since == "" {
			since = "1970-01-01T00:00:00Z"
		}

		msgs, err := db.GetMessages(sessionID, since, 200)
		if err != nil {
			errorJSON(w, 500, "查询消息失败: "+err.Error())
			return
		}
		if msgs == nil {
			msgs = []store.Message{}
		}

		// 获取session的typing状态
		typingState := false
		if sess, err := db.GetOrCreateSession(sessionID, ""); err == nil {
			typingState = sess.TypingState
		}

		writeJSON(w, 200, map[string]interface{}{
			"messages":     msgs,
			"count":        len(msgs),
			"typing_state": typingState,
		})
	}
}

// AckMessage 手机端确认消息已收到
func AckMessage(db *store.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		id := r.PathValue("id")
		if id == "" {
			errorJSON(w, 400, "需要消息 ID")
			return
		}
		if err := db.AckMessage(id); err != nil {
			errorJSON(w, 500, "确认失败: "+err.Error())
			return
		}
		writeJSON(w, 200, map[string]string{"status": "delivered"})
	}
}

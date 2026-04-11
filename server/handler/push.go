package handler

import (
	"encoding/base64"
	"fmt"
	"io"
	"net/http"
	"os"
	"time"

	"push-server/store"
	"push-server/ws"

	"github.com/google/uuid"
)

// PushMessage PC端推送文本消息
func PushMessage(db *store.DB, hub *ws.Hub) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			SessionID      string `json:"session_id"`
			ConversationID string `json:"conversation_id"`
			Content        string `json:"content"`
			MsgType        string `json:"msg_type"`
			ChunkIndex     int    `json:"chunk_index"`
			IsFinal        bool   `json:"is_final"`
		}
		if err := readJSON(r, &req); err != nil {
			errorJSON(w, 400, "无效的请求体")
			return
		}
		if req.SessionID == "" || req.Content == "" {
			errorJSON(w, 400, "session_id 和 content 不能为空")
			return
		}
		if req.MsgType == "" {
			req.MsgType = "text"
		}

		// 确保 session 存在
		db.GetOrCreateSession(req.SessionID, "")
		db.TouchSession(req.SessionID)

		// typing / stop_typing 状态消息：广播+更新session状态
		if req.MsgType == "typing" || req.MsgType == "stop_typing" {
			db.SetTypingState(req.SessionID, req.MsgType == "typing")
			hub.BroadcastToSession(req.SessionID, map[string]interface{}{
				"type": "message",
				"data": map[string]interface{}{
					"id":         req.MsgType + "_" + req.SessionID,
					"session_id": req.SessionID,
					"content":    req.Content,
					"msg_type":   req.MsgType,
					"sender":     "pc",
					"created_at": time.Now().UTC().Format(time.RFC3339),
				},
			})
			writeJSON(w, 200, map[string]interface{}{
				"success": true,
				"typing":  req.MsgType == "typing",
			})
			return
		}

		msg := &store.Message{
			ID:             uuid.New().String(),
			SessionID:      req.SessionID,
			ConversationID: req.ConversationID,
			Content:        req.Content,
			MsgType:        req.MsgType,
			Sender:         "pc",
			ChunkIndex:     req.ChunkIndex,
			IsFinal:        req.IsFinal,
			Status:         "pending",
			CreatedAt:      time.Now().UTC().Format(time.RFC3339),
		}

		if err := db.InsertMessage(msg); err != nil {
			errorJSON(w, 500, "消息存储失败: "+err.Error())
			return
		}

		// 广播给在线的手机客户端
		hub.BroadcastToSession(req.SessionID, map[string]interface{}{
			"type": "message",
			"data": msg,
		})

		online := hub.OnlineCount(req.SessionID)
		writeJSON(w, 200, map[string]interface{}{
			"success":      true,
			"message_id":   msg.ID,
			"online_count": online,
		})
	}
}

// PushImage PC端推送图片/截图
// 将图片保存为文件并作为file类型消息广播，使App能渲染图片预览
func PushImage(db *store.DB, hub *ws.Hub) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			SessionID      string `json:"session_id"`
			ConversationID string `json:"conversation_id"`
			Content        string `json:"content"`
			ImageBase64    string `json:"image_base64"`
		}
		if err := readJSON(r, &req); err != nil {
			// 尝试 multipart
			r.Body = http.MaxBytesReader(w, r.Body, 10<<20) // 10MB
			if err := r.ParseMultipartForm(10 << 20); err != nil {
				errorJSON(w, 400, "无效的请求体")
				return
			}
			req.SessionID = r.FormValue("session_id")
			req.ConversationID = r.FormValue("conversation_id")
			req.Content = r.FormValue("content")
			file, _, err := r.FormFile("image")
			if err != nil {
				errorJSON(w, 400, "缺少图片文件")
				return
			}
			defer file.Close()
			imgData, _ := io.ReadAll(file)
			req.ImageBase64 = base64.StdEncoding.EncodeToString(imgData)
		}

		if req.SessionID == "" {
			errorJSON(w, 400, "session_id 不能为空")
			return
		}

		imgData, err := base64.StdEncoding.DecodeString(req.ImageBase64)
		if err != nil {
			errorJSON(w, 400, "图片 base64 解码失败")
			return
		}

		db.GetOrCreateSession(req.SessionID, "")
		db.TouchSession(req.SessionID)

		// 将图片保存为文件（复用文件下载基础设施）
		fileID := uuid.New().String()
		fileName := "screenshot.png"
		uploadDir := "data/uploads/" + req.SessionID
		os.MkdirAll(uploadDir, 0755)
		filePath := uploadDir + "/" + fileID + ".png"
		if err := os.WriteFile(filePath, imgData, 0644); err != nil {
			errorJSON(w, 500, "图片保存失败: "+err.Error())
			return
		}

		caption := req.Content
		if caption == "" {
			caption = "截图"
		}
		content := fmt.Sprintf("📎 %s\n文件: %s (%s)", caption, fileName, humanSize(int64(len(imgData))))

		msg := &store.Message{
			ID:        fileID,
			SessionID: req.SessionID,
			Content:   content,
			MsgType:   "file",
			HasImage:  true,
			Sender:    "pc",
			IsFinal:   true,
			Status:    "pending",
			CreatedAt: time.Now().UTC().Format(time.RFC3339),
		}

		if err := db.InsertMessage(msg); err != nil {
			errorJSON(w, 500, "消息存储失败: "+err.Error())
			return
		}

		// 广播为file类型，App可直接渲染图片预览
		hub.BroadcastToSession(req.SessionID, map[string]interface{}{
			"type": "message",
			"data": map[string]interface{}{
				"id":           fileID,
				"session_id":   req.SessionID,
				"content":      content,
				"caption":      caption,
				"msg_type":     "file",
				"sender":       "pc",
				"has_image":    true,
				"file_name":    fileName,
				"file_size":    len(imgData),
				"file_id":      fileID,
				"file_ext":     ".png",
				"download_url": fmt.Sprintf("/api/files/%s?session_id=%s", fileID, req.SessionID),
				"created_at":   msg.CreatedAt,
			},
		})

		writeJSON(w, 200, map[string]interface{}{
			"success":    true,
			"message_id": fileID,
			"image_size": len(imgData),
		})
	}
}

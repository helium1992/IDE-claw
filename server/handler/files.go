package handler

import (
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"push-server/config"
	"push-server/store"
	"push-server/ws"

	"github.com/google/uuid"
)

// UploadFile 处理文件上传（PC或手机均可上传）
func UploadFile(db *store.DB, hub *ws.Hub) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		// 限制上传大小 500MB，但内存缓冲仅32MB（其余写临时文件）
		r.Body = http.MaxBytesReader(w, r.Body, 500<<20)

		if err := r.ParseMultipartForm(32 << 20); err != nil {
			errorJSON(w, http.StatusBadRequest, "文件太大或格式错误")
			return
		}

		sessionID := r.FormValue("session_id")
		sender := r.FormValue("sender") // "pc" or "mobile"
		caption := r.FormValue("caption")

		if sessionID == "" {
			errorJSON(w, http.StatusBadRequest, "session_id 必填")
			return
		}
		if sender == "" {
			sender = "pc"
		}

		file, header, err := r.FormFile("file")
		if err != nil {
			errorJSON(w, http.StatusBadRequest, "获取文件失败: "+err.Error())
			return
		}
		defer file.Close()

		// 生成唯一文件名
		fileID := uuid.New().String()
		ext := filepath.Ext(header.Filename)
		storedName := fileID + ext

		// 存储目录
		uploadDir := filepath.Join("data", "uploads", sessionID)
		if err := os.MkdirAll(uploadDir, 0755); err != nil {
			errorJSON(w, http.StatusInternalServerError, "创建目录失败")
			return
		}

		destPath := filepath.Join(uploadDir, storedName)
		dst, err := os.Create(destPath)
		if err != nil {
			errorJSON(w, http.StatusInternalServerError, "创建文件失败")
			return
		}
		defer dst.Close()

		written, err := io.Copy(dst, file)
		if err != nil {
			errorJSON(w, http.StatusInternalServerError, "保存文件失败")
			return
		}

		// 构建消息内容
		if caption == "" {
			caption = header.Filename
		}
		content := fmt.Sprintf("📎 文件: %s (%s)", header.Filename, humanSize(written))
		if caption != header.Filename {
			content = fmt.Sprintf("📎 %s\n文件: %s (%s)", caption, header.Filename, humanSize(written))
		}

		// 创建消息记录
		msg := store.Message{
			ID:        fileID,
			SessionID: sessionID,
			Content:   content,
			MsgType:   "file",
			HasImage:  isImageFile(ext),
			Sender:    sender,
			IsFinal:   true,
			Status:    "pending",
			CreatedAt: time.Now().UTC().Format(time.RFC3339),
		}
		if err := db.InsertMessage(&msg); err != nil {
			log.Printf("保存文件消息失败: %v", err)
		}

		// 如果是手机端上传，也创建一条 command 让 PC 端的长轮询能收到通知
		if sender == "mobile" {
			fileParams := fmt.Sprintf(`{"file_id":"%s","file_name":"%s","file_size":%d}`, fileID, header.Filename, written)
			cmd := store.Command{
				ID:        uuid.New().String(),
				SessionID: sessionID,
				Command:   "file_uploaded",
				Params:    fileParams,
				Status:    "pending",
				CreatedAt: time.Now().UTC().Format(time.RFC3339),
			}
			if err := db.InsertCommand(&cmd); err != nil {
				log.Printf("创建文件指令失败: %v", err)
			}
		}

		// 通过 WebSocket 通知对方
		hub.BroadcastToSession(sessionID, map[string]interface{}{
			"type": "message",
			"data": map[string]interface{}{
				"id":           fileID,
				"session_id":   sessionID,
				"content":      content,
				"caption":      caption,
				"msg_type":     "file",
				"sender":       sender,
				"has_image":    isImageFile(ext),
				"file_name":    header.Filename,
				"file_size":    written,
				"file_id":      fileID,
				"file_ext":     ext,
				"download_url": fmt.Sprintf("/api/files/%s?session_id=%s", fileID, sessionID),
				"created_at":   msg.CreatedAt,
			},
		})

		writeJSON(w, http.StatusOK, map[string]interface{}{
			"success":   true,
			"file_id":   fileID,
			"file_name": header.Filename,
			"file_size": written,
			"file_ext":  ext,
		})
	}
}

// DownloadFile 处理文件下载
func DownloadFile(cfg *config.Config) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		fileID := r.PathValue("id")
		sessionID := r.URL.Query().Get("session_id")

		if fileID == "" || sessionID == "" {
			errorJSON(w, http.StatusBadRequest, "file_id 和 session_id 必填")
			return
		}

		// 查找文件
		uploadDir := filepath.Join("data", "uploads", sessionID)
		entries, err := os.ReadDir(uploadDir)
		if err != nil {
			errorJSON(w, http.StatusNotFound, "文件不存在")
			return
		}

		var targetPath string
		for _, entry := range entries {
			if strings.HasPrefix(entry.Name(), fileID) {
				targetPath = filepath.Join(uploadDir, entry.Name())
				break
			}
		}

		if targetPath == "" {
			errorJSON(w, http.StatusNotFound, "文件不存在")
			return
		}

		// 设置下载头
		w.Header().Set("Content-Disposition", fmt.Sprintf("attachment; filename=\"%s\"", filepath.Base(targetPath)))
		http.ServeFile(w, r, targetPath)
	}
}

func humanSize(bytes int64) string {
	const unit = 1024
	if bytes < unit {
		return fmt.Sprintf("%d B", bytes)
	}
	div, exp := int64(unit), 0
	for n := bytes / unit; n >= unit; n /= unit {
		div *= unit
		exp++
	}
	return fmt.Sprintf("%.1f %cB", float64(bytes)/float64(div), "KMGTPE"[exp])
}

func isImageFile(ext string) bool {
	ext = strings.ToLower(ext)
	return ext == ".jpg" || ext == ".jpeg" || ext == ".png" ||
		ext == ".gif" || ext == ".webp" || ext == ".bmp"
}

package main

import (
	"fmt"
	"log"
	"net/http"
	"os"
	"time"

	"push-server/config"
	"push-server/handler"
	"push-server/store"
	"push-server/ws"
)

func main() {
	cfg := config.Load()

	// 初始化数据库
	db, err := store.InitDB(cfg.DBPath)
	if err != nil {
		log.Fatalf("数据库初始化失败: %v", err)
	}
	defer db.Close()

	// 定时清理3天前的数据
	go func() {
		for {
			n, err := db.CleanupOldData(3)
			if err != nil {
				log.Printf("数据清理失败: %v", err)
			} else if n > 0 {
				log.Printf("已清理 %d 条过期数据(>3天)", n)
			}
			time.Sleep(6 * time.Hour)
		}
	}()

	// 初始化 WebSocket Hub
	hub := ws.NewHub()
	go hub.Run()

	// 注册路由
	mux := http.NewServeMux()

	// 健康检查
	mux.HandleFunc("GET /api/health", handler.Health(cfg))

	// 认证
	mux.HandleFunc("POST /api/auth/token", handler.AuthToken(db, cfg))

	// 推送消息（PC→服务器）
	mux.HandleFunc("POST /api/push", handler.RequireAuth(cfg, handler.PushMessage(db, hub)))
	mux.HandleFunc("POST /api/push/image", handler.RequireAuth(cfg, handler.PushImage(db, hub)))

	// 会话列表 & 元数据更新
	mux.HandleFunc("GET /api/sessions", handler.RequireAuth(cfg, handler.ListSessions(db)))
	mux.HandleFunc("POST /api/sessions/meta", handler.RequireAuth(cfg, handler.UpdateSessionMeta(db)))
	mux.HandleFunc("POST /api/sessions/mark_read", handler.RequireAuth(cfg, handler.MarkSessionRead(db)))

	// P2P直连端点注册/发现
	mux.HandleFunc("POST /api/sessions/register-endpoint", handler.RequireAuth(cfg, handler.RegisterEndpoint(cfg)))
	mux.HandleFunc("GET /api/sessions/endpoint", handler.RequireAuth(cfg, handler.GetEndpoint(cfg)))

	// 拉取消息（手机端）
	mux.HandleFunc("GET /api/messages", handler.RequireAuth(cfg, handler.GetMessages(db)))
	mux.HandleFunc("POST /api/messages/{id}/ack", handler.RequireAuth(cfg, handler.AckMessage(db)))

	// 反向指令（手机→PC）
	mux.HandleFunc("POST /api/commands", handler.RequireAuth(cfg, handler.CreateCommand(db, hub)))
	mux.HandleFunc("GET /api/commands/pending", handler.RequireAuth(cfg, handler.GetPendingCommands(db)))
	mux.HandleFunc("POST /api/commands/{id}/result", handler.RequireAuth(cfg, handler.CommandResult(db)))

	// 文件上传/下载
	mux.HandleFunc("POST /api/files/upload", handler.RequireAuth(cfg, handler.UploadFile(db, hub)))
	mux.HandleFunc("GET /api/files/{id}", handler.RequireAuth(cfg, handler.DownloadFile(cfg)))

	// 公开下载（APK等）
	mux.Handle("GET /dl/", http.StripPrefix("/dl/", http.FileServer(http.Dir("data/uploads"))))

	// WebRTC信令
	mux.HandleFunc("POST /api/webrtc/signal", handler.RequireAuth(cfg, handler.PostSignal(hub, cfg)))
	mux.HandleFunc("GET /api/webrtc/signals", handler.RequireAuth(cfg, handler.GetSignals(cfg)))
	mux.HandleFunc("GET /api/webrtc/turn-credentials", handler.RequireAuth(cfg, handler.GetTurnCredentials(cfg)))

	// Windsurf 账号管理
	mux.HandleFunc("POST /api/windsurf/login", handler.RequireAuth(cfg, handler.WindsurfLogin(db, cfg)))
	mux.HandleFunc("POST /api/windsurf/firebase/login", handler.RequireAuth(cfg, handler.WindsurfFirebaseLogin(db, cfg)))
	mux.HandleFunc("POST /api/windsurf/auth-token", handler.RequireAuth(cfg, handler.WindsurfAuthToken(db, cfg)))
	mux.HandleFunc("POST /api/windsurf/plan-status", handler.RequireAuth(cfg, handler.WindsurfPlanStatus(db, cfg)))
	mux.HandleFunc("POST /api/windsurf/accounts", handler.RequireAuth(cfg, handler.ImportWindsurfAccounts(db, cfg)))
	mux.HandleFunc("GET /api/windsurf/accounts", handler.RequireAuth(cfg, handler.ListWindsurfAccounts(db, cfg)))
	mux.HandleFunc("POST /api/windsurf/claim", handler.RequireAuth(cfg, handler.ClaimWindsurfAccount(db, cfg)))
	mux.HandleFunc("POST /api/windsurf/release", handler.RequireAuth(cfg, handler.ReleaseWindsurfAccount(db, cfg)))
	mux.HandleFunc("GET /api/windsurf/status", handler.RequireAuth(cfg, handler.WindsurfAccountStatus(db, cfg)))

	// WebSocket
	mux.HandleFunc("GET /ws", handler.WSHandler(hub, db, cfg))

	// 等待指令回复（PC端长轮询）
	mux.HandleFunc("GET /api/commands/wait", handler.RequireAuth(cfg, handler.WaitCommand(db)))

	// CORS 中间件
	wrapped := corsMiddleware(mux)

	addr := fmt.Sprintf(":%d", cfg.Port)
	fmt.Printf("🚀 Push Server 启动: http://127.0.0.1%s\n", addr)
	fmt.Printf("   POST /api/push       — 推送消息\n")
	fmt.Printf("   GET  /ws             — WebSocket\n")
	fmt.Printf("   GET  /api/health     — 健康检查\n")

	if err := http.ListenAndServe(addr, wrapped); err != nil {
		log.Fatalf("服务启动失败: %v", err)
	}
}

func corsMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization")
		if r.Method == "OPTIONS" {
			w.WriteHeader(204)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func init() {
	// 确保日志输出到 stdout
	log.SetOutput(os.Stdout)
	log.SetFlags(log.LstdFlags | log.Lshortfile)
}

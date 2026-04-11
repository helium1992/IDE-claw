package ws

import (
	"encoding/json"
	"log"
	"sync"
)

type Hub struct {
	mu         sync.RWMutex
	clients    map[string]map[*Client]bool // sessionID → set of clients
	broadcast  chan *BroadcastMsg
	register   chan *Client
	unregister chan *Client
}

type BroadcastMsg struct {
	SessionID string
	Data      json.RawMessage
}

func NewHub() *Hub {
	return &Hub{
		clients:    make(map[string]map[*Client]bool),
		broadcast:  make(chan *BroadcastMsg, 256),
		register:   make(chan *Client),
		unregister: make(chan *Client),
	}
}

func (h *Hub) Run() {
	for {
		select {
		case client := <-h.register:
			h.mu.Lock()
			if _, ok := h.clients[client.SessionID]; !ok {
				h.clients[client.SessionID] = make(map[*Client]bool)
			}
			h.clients[client.SessionID][client] = true
			h.mu.Unlock()
			log.Printf("📱 客户端连接: session=%s, role=%s", client.SessionID, client.Role)

		case client := <-h.unregister:
			h.mu.Lock()
			if clients, ok := h.clients[client.SessionID]; ok {
				if _, exists := clients[client]; exists {
					delete(clients, client)
					close(client.Send)
					if len(clients) == 0 {
						delete(h.clients, client.SessionID)
					}
				}
			}
			h.mu.Unlock()
			log.Printf("📱 客户端断开: session=%s, role=%s", client.SessionID, client.Role)

		case msg := <-h.broadcast:
			h.mu.RLock()
			if clients, ok := h.clients[msg.SessionID]; ok {
				for client := range clients {
					select {
					case client.Send <- msg.Data:
					default:
						// 发送缓冲满，关闭连接
						close(client.Send)
						delete(clients, client)
					}
				}
			}
			h.mu.RUnlock()
		}
	}
}

func (h *Hub) BroadcastToSession(sessionID string, data interface{}) {
	jsonData, err := json.Marshal(data)
	if err != nil {
		log.Printf("JSON序列化失败: %v", err)
		return
	}
	h.broadcast <- &BroadcastMsg{
		SessionID: sessionID,
		Data:      jsonData,
	}
}

func (h *Hub) Register(client *Client) {
	h.register <- client
}

func (h *Hub) Unregister(client *Client) {
	h.unregister <- client
}

func (h *Hub) OnlineCount(sessionID string) int {
	h.mu.RLock()
	defer h.mu.RUnlock()
	return len(h.clients[sessionID])
}

// BroadcastToSessionRole 向指定session的指定角色发送消息
func (h *Hub) BroadcastToSessionRole(sessionID, role string, data json.RawMessage) {
	h.mu.RLock()
	defer h.mu.RUnlock()
	if clients, ok := h.clients[sessionID]; ok {
		for client := range clients {
			if client.Role == role {
				select {
				case client.Send <- data:
				default:
				}
			}
		}
	}
}

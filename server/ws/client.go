package ws

import (
	"encoding/json"
	"log"
	"time"

	"github.com/gorilla/websocket"
)

const (
	writeWait      = 15 * time.Second
	pongWait       = 120 * time.Second
	pingPeriod     = 45 * time.Second
	maxMessageSize = 1 << 20 // 1MB
)

type Client struct {
	Hub       *Hub
	Conn      *websocket.Conn
	Send      chan json.RawMessage
	SessionID string
	Role      string // "mobile" or "pc"
}

type WSMessage struct {
	Type      string          `json:"type"`
	Data      json.RawMessage `json:"data,omitempty"`
	MessageID string          `json:"message_id,omitempty"`
}

func (c *Client) ReadPump(onMessage func(*Client, WSMessage)) {
	defer func() {
		c.Hub.unregister <- c
		c.Conn.Close()
	}()

	c.Conn.SetReadLimit(maxMessageSize)
	c.Conn.SetReadDeadline(time.Now().Add(pongWait))
	c.Conn.SetPongHandler(func(string) error {
		c.Conn.SetReadDeadline(time.Now().Add(pongWait))
		return nil
	})

	for {
		_, raw, err := c.Conn.ReadMessage()
		if err != nil {
			if websocket.IsUnexpectedCloseError(err, websocket.CloseGoingAway, websocket.CloseNormalClosure) {
				log.Printf("WebSocket 读取错误: %v", err)
			}
			break
		}

		var msg WSMessage
		if err := json.Unmarshal(raw, &msg); err != nil {
			log.Printf("WebSocket 消息解析失败: %v", err)
			continue
		}

		if msg.Type == "ping" {
			reply, _ := json.Marshal(WSMessage{Type: "pong"})
			select {
			case c.Send <- reply:
			default:
			}
			continue
		}

		if onMessage != nil {
			onMessage(c, msg)
		}
	}
}

func (c *Client) WritePump() {
	ticker := time.NewTicker(pingPeriod)
	defer func() {
		ticker.Stop()
		c.Conn.Close()
	}()

	for {
		select {
		case msg, ok := <-c.Send:
			c.Conn.SetWriteDeadline(time.Now().Add(writeWait))
			if !ok {
				c.Conn.WriteMessage(websocket.CloseMessage, []byte{})
				return
			}
			if err := c.Conn.WriteMessage(websocket.TextMessage, msg); err != nil {
				return
			}

		case <-ticker.C:
			c.Conn.SetWriteDeadline(time.Now().Add(writeWait))
			if err := c.Conn.WriteMessage(websocket.PingMessage, nil); err != nil {
				return
			}
		}
	}
}

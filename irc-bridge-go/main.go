package main

import (
    "bufio"
    "log"
    "net"
    "net/http"
    "sync"
    "time"
    
    "github.com/gorilla/websocket"
)

var upgrader = websocket.Upgrader{
    CheckOrigin: func(r *http.Request) bool {
        return true
    },
    ReadBufferSize:  1024,
    WriteBufferSize: 1024,
}

type Client struct {
    conn   *websocket.Conn
    irc    net.Conn
    send   chan []byte
    mu     sync.Mutex
}

type Hub struct {
    clients    map[*Client]bool
    register   chan *Client
    unregister chan *Client
    mu         sync.RWMutex
}

func newHub() *Hub {
    return &Hub{
        clients:    make(map[*Client]bool),
        register:   make(chan *Client),
        unregister: make(chan *Client),
    }
}

func (h *Hub) run() {
    for {
        select {
        case client := <-h.register:
            h.mu.Lock()
            h.clients[client] = true
            h.mu.Unlock()
            log.Printf("Client connected. Total: %d", len(h.clients))
            
        case client := <-h.unregister:
            h.mu.Lock()
            if _, ok := h.clients[client]; ok {
                delete(h.clients, client)
                close(client.send)
                if client.irc != nil {
                    client.irc.Close()
                }
            }
            h.mu.Unlock()
            log.Printf("Client disconnected. Total: %d", len(h.clients))
        }
    }
}

func (c *Client) readPump(hub *Hub) {
    defer func() {
        hub.unregister <- c
        c.conn.Close()
    }()
    
    c.conn.SetReadLimit(512)
    c.conn.SetReadDeadline(time.Now().Add(60 * time.Second))
    c.conn.SetPongHandler(func(string) error {
        c.conn.SetReadDeadline(time.Now().Add(60 * time.Second))
        return nil
    })
    
    for {
        _, message, err := c.conn.ReadMessage()
        if err != nil {
            break
        }
        
        if c.irc != nil {
            c.mu.Lock()
            c.irc.Write(append(message, '\r', '\n'))
            c.mu.Unlock()
        }
    }
}

func (c *Client) writePump() {
    ticker := time.NewTicker(54 * time.Second)
    defer ticker.Stop()
    
    for {
        select {
        case message, ok := <-c.send:
            c.conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
            if !ok {
                c.conn.WriteMessage(websocket.CloseMessage, []byte{})
                return
            }
            
            c.conn.WriteMessage(websocket.TextMessage, message)
            
        case <-ticker.C:
            c.conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
            if err := c.conn.WriteMessage(websocket.PingMessage, nil); err != nil {
                return
            }
        }
    }
}

func (c *Client) ircPump() {
    if c.irc == nil {
        return
    }
    
    scanner := bufio.NewScanner(c.irc)
    for scanner.Scan() {
        select {
        case c.send <- scanner.Bytes():
        default:
            close(c.send)
            return
        }
    }
}

func handleWebSocket(hub *Hub, w http.ResponseWriter, r *http.Request) {
    conn, err := upgrader.Upgrade(w, r, nil)
    if err != nil {
        log.Println("Upgrade error:", err)
        return
    }
    
    // Connect to IRC server
    ircConn, err := net.DialTimeout("tcp", "ngircd:6667", 5*time.Second)
    if err != nil {
        log.Println("IRC connection error:", err)
        conn.Close()
        return
    }
    
    client := &Client{
        conn: conn,
        irc:  ircConn,
        send: make(chan []byte, 256),
    }
    
    hub.register <- client
    
    go client.writePump()
    go client.ircPump()
    go client.readPump(hub)
}

func main() {
    hub := newHub()
    go hub.run()
    
    http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
        handleWebSocket(hub, w, r)
    })
    
    log.Println("* IRC Bridge starting on :3000")
    log.Fatal(http.ListenAndServe(":3000", nil))
} 
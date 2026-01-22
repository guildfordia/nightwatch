package main

import (
    "bufio"
    "crypto/sha1"
    "encoding/base64"
    "fmt"
    "log"
    "net"
    "net/http"
    "strings"
    "sync"
    "time"
)

// Simple WebSocket implementation using standard library
type Client struct {
    conn   net.Conn
    irc    net.Conn
    send   chan []byte
    mu     sync.Mutex
    id     string
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
            log.Printf("[%s] Client registered. Total: %d", client.id, len(h.clients))

        case client := <-h.unregister:
            h.mu.Lock()
            if _, ok := h.clients[client]; ok {
                delete(h.clients, client)
                close(client.send)
                if client.irc != nil {
                    log.Printf("[%s] Closing IRC connection", client.id)
                    client.irc.Close()
                }
            }
            h.mu.Unlock()
            log.Printf("[%s] Client unregistered. Total: %d", client.id, len(h.clients))
        }
    }
}

func (c *Client) readPump(hub *Hub) {
    defer func() {
        log.Printf("[%s] WebSocket readPump ending, unregistering client", c.id)
        hub.unregister <- c
        c.conn.Close()
    }()

    log.Printf("[%s] Starting WebSocket readPump", c.id)

    for {
        // Read WebSocket frame
        message, err := c.readWebSocketFrame()
        if err != nil {
            log.Printf("[%s] WebSocket read error: %v", c.id, err)
            break
        }

        if message != "" {
            log.Printf("[%s] WebSocket received: %q", c.id, message)
            if c.irc != nil {
                c.mu.Lock()
                _, writeErr := c.irc.Write([]byte(message + "\r\n"))
                c.mu.Unlock()
                if writeErr != nil {
                    log.Printf("[%s] IRC write error: %v", c.id, writeErr)
                    break
                }
                log.Printf("[%s] Sent to IRC: %s", c.id, message)
            }
        }
    }
}

func (c *Client) readWebSocketFrame() (string, error) {
    // Read frame header (at least 2 bytes)
    header := make([]byte, 2)
    _, err := c.conn.Read(header)
    if err != nil {
        return "", err
    }

    // Check if this is a text frame
    opcode := header[0] & 0x0F
    if opcode == 0x08 { // Close frame
        return "", fmt.Errorf("client sent close frame")
    }
    if opcode != 0x01 { // Not a text frame
        return "", fmt.Errorf("unsupported frame type: %d", opcode)
    }

    // Get payload length
    masked := (header[1] & 0x80) != 0
    length := int(header[1] & 0x7F)

    if length == 126 {
        lengthBytes := make([]byte, 2)
        _, err := c.conn.Read(lengthBytes)
        if err != nil {
            return "", err
        }
        length = int(lengthBytes[0])<<8 | int(lengthBytes[1])
    } else if length == 127 {
        lengthBytes := make([]byte, 8)
        _, err := c.conn.Read(lengthBytes)
        if err != nil {
            return "", err
        }
        // For simplicity, only handle reasonable lengths
        length = int(lengthBytes[4])<<24 | int(lengthBytes[5])<<16 | int(lengthBytes[6])<<8 | int(lengthBytes[7])
    }

    // Read mask key if present
    var maskKey []byte
    if masked {
        maskKey = make([]byte, 4)
        _, err := c.conn.Read(maskKey)
        if err != nil {
            return "", err
        }
    }

    // Read payload
    payload := make([]byte, length)
    _, err = c.conn.Read(payload)
    if err != nil {
        return "", err
    }

    // Unmask payload if necessary
    if masked {
        for i := 0; i < length; i++ {
            payload[i] ^= maskKey[i%4]
        }
    }

    return strings.TrimSpace(string(payload)), nil
}

func (c *Client) writePump() {
    log.Printf("[%s] Starting WebSocket writePump", c.id)
    defer log.Printf("[%s] WebSocket writePump ending", c.id)

    for {
        select {
        case message, ok := <-c.send:
            if !ok {
                log.Printf("[%s] Send channel closed", c.id)
                return
            }

            // Send as WebSocket text frame
            frame := createWebSocketFrame(message)
            _, err := c.conn.Write(frame)
            if err != nil {
                log.Printf("[%s] WebSocket write error: %v", c.id, err)
                return
            }
            // Reduced logging - only log first few messages or errors
            if len(c.send) > 250 || strings.Contains(string(message), "001") || strings.Contains(string(message), "JOIN") {
                log.Printf("[%s] Sent to WebSocket: %q", c.id, string(message))
            }
        }
    }
}

func createWebSocketFrame(data []byte) []byte {
    length := len(data)
    var frame []byte

    // WebSocket frame format:
    // Byte 0: FIN (1) + RSV (000) + Opcode (0001 for text)
    frame = append(frame, 0x81) // 10000001 = FIN + text frame

    if length < 126 {
        frame = append(frame, byte(length))
    } else if length < 65536 {
        frame = append(frame, 126)
        frame = append(frame, byte(length>>8))
        frame = append(frame, byte(length&0xFF))
    } else {
        frame = append(frame, 127)
        for i := 7; i >= 0; i-- {
            frame = append(frame, byte((length>>(8*i))&0xFF))
        }
    }

    frame = append(frame, data...)
    return frame
}

func (c *Client) ircPump() {
    if c.irc == nil {
        log.Printf("[%s] IRC connection is nil, cannot start ircPump", c.id)
        return
    }

    log.Printf("[%s] Starting IRC readPump", c.id)
    defer log.Printf("[%s] IRC readPump ending", c.id)

    scanner := bufio.NewScanner(c.irc)
    for scanner.Scan() {
        line := scanner.Text()
        // Only log important IRC messages to reduce spam
        if strings.Contains(line, "001") || strings.Contains(line, "JOIN") || strings.Contains(line, "PRIVMSG") || strings.Contains(line, "PART") || strings.Contains(line, "QUIT") || strings.Contains(line, "NICK") {
            log.Printf("[%s] IRC received: %s", c.id, line)
        }
        select {
        case c.send <- []byte(line + "\n"):
            // Message sent to WebSocket
        default:
            log.Printf("[%s] Send channel blocked, closing", c.id)
            close(c.send)
            return
        }
    }

    if err := scanner.Err(); err != nil {
        log.Printf("[%s] IRC scanner error: %v", c.id, err)
    }
}

func handleWebSocket(hub *Hub, w http.ResponseWriter, r *http.Request) {
    clientID := fmt.Sprintf("client-%d", time.Now().UnixNano()%10000)
    log.Printf("[%s] New WebSocket request from %s", clientID, r.RemoteAddr)

    // Simple WebSocket handshake
    if r.Header.Get("Upgrade") != "websocket" {
        log.Printf("[%s] Not a websocket request", clientID)
        http.Error(w, "Not a websocket request", 400)
        return
    }

    key := r.Header.Get("Sec-WebSocket-Key")
    if key == "" {
        log.Printf("[%s] Missing websocket key", clientID)
        http.Error(w, "Missing websocket key", 400)
        return
    }

    log.Printf("[%s] WebSocket key: %s", clientID, key)

    // WebSocket handshake response
    acceptKey := computeAcceptKey(key)
    log.Printf("[%s] WebSocket accept key: %s", clientID, acceptKey)

    hijacker, ok := w.(http.Hijacker)
    if !ok {
        log.Printf("[%s] Cannot hijack connection", clientID)
        http.Error(w, "Cannot hijack connection", 500)
        return
    }

    conn, _, err := hijacker.Hijack()
    if err != nil {
        log.Printf("[%s] Cannot hijack connection: %v", clientID, err)
        http.Error(w, "Cannot hijack connection", 500)
        return
    }

    log.Printf("[%s] Connection hijacked successfully", clientID)

    // Send WebSocket handshake response
    response := fmt.Sprintf(
        "HTTP/1.1 101 Switching Protocols\r\n"+
        "Upgrade: websocket\r\n"+
        "Connection: Upgrade\r\n"+
        "Sec-WebSocket-Accept: %s\r\n\r\n",
        acceptKey)

    _, writeErr := conn.Write([]byte(response))
    if writeErr != nil {
        log.Printf("[%s] Failed to write WebSocket handshake: %v", clientID, writeErr)
        conn.Close()
        return
    }

    log.Printf("[%s] WebSocket handshake sent", clientID)

    // Connect to IRC server
    log.Printf("[%s] Connecting to IRC server ngircd:6667", clientID)
    ircConn, err := net.DialTimeout("tcp", "ngircd:6667", 5*time.Second)
    if err != nil {
        log.Printf("[%s] IRC connection error: %v", clientID, err)
        conn.Close()
        return
    }

    // Immediately register as "guest"
    if _, err := ircConn.Write([]byte("NICK guest\r\nUSER guest 0 * :Web User\r\n")); err != nil {
        log.Printf("IRC pre-registration failed: %v", err)
        conn.Close()
        ircConn.Close()
        return
    }

    log.Printf("[%s] IRC connection established", clientID)

    // Authenticate with IRC server
    nick := fmt.Sprintf("webuser%d", time.Now().Unix()%1000)
    log.Printf("[%s] Authenticating with IRC as %s", clientID, nick)

    _, err1 := ircConn.Write([]byte(fmt.Sprintf("NICK %s\r\n", nick)))
    _, err2 := ircConn.Write([]byte(fmt.Sprintf("USER %s 0 * :Web User\r\n", nick)))
    _, err3 := ircConn.Write([]byte("JOIN #nightwatch\r\n"))

    if err1 != nil || err2 != nil || err3 != nil {
        log.Printf("[%s] IRC auth write errors: %v, %v, %v", clientID, err1, err2, err3)
        ircConn.Close()
        conn.Close()
        return
    }

    log.Printf("[%s] IRC authentication commands sent", clientID)

    client := &Client{
        conn: conn,
        irc:  ircConn,
        send: make(chan []byte, 256),
        id:   clientID,
    }

    hub.register <- client

    log.Printf("[%s] Starting client goroutines", clientID)
    go client.writePump()
    go client.ircPump()
    go client.readPump(hub)
}

func computeAcceptKey(key string) string {
    h := sha1.New()
    h.Write([]byte(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
    return base64.StdEncoding.EncodeToString(h.Sum(nil))
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

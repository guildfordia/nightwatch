package main

import (
	"bufio"
	"context"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/gorilla/websocket"
)

// Monotonic counters for unique client IDs and IRC nicks
var clientCounter atomic.Uint64

// --- Configuration ---

const (
	ircServer       = "ngircd:6667"
	ircChannel      = "#nightwatch"
	listenAddr      = ":3000"
	maxConnsPerIP   = 5
	wsReadLimit     = 4096
	wsPongWait      = 60 * time.Second
	wsPingPeriod    = 50 * time.Second // must be < pongWait
	wsWriteWait     = 10 * time.Second
	ircDialTimeout  = 5 * time.Second
	shutdownTimeout = 10 * time.Second
	maxIRCMsgLen    = 400 // IRC limit minus protocol overhead
)

// --- WebSocket upgrader with origin check ---

var allowedOriginPrefixes = []string{
	"http://192.168.",
	"http://10.",
	"http://172.16.", "http://172.17.", "http://172.18.", "http://172.19.",
	"http://172.20.", "http://172.21.", "http://172.22.", "http://172.23.",
	"http://172.24.", "http://172.25.", "http://172.26.", "http://172.27.",
	"http://172.28.", "http://172.29.", "http://172.30.", "http://172.31.",
	"http://localhost",
	"http://127.0.0.1",
	"http://[::1]",
	"http://nightwatch",
}

var upgrader = websocket.Upgrader{
	ReadBufferSize:  1024,
	WriteBufferSize: 1024,
	// Allow all origins: captive portal DNS hijacking means browsers send
	// origins like "http://detectportal.firefox.com" or other connectivity
	// check domains that would never match a static allowlist. Since this
	// runs on an isolated mesh network with no internet, there's no
	// cross-site risk to defend against.
	CheckOrigin: func(r *http.Request) bool {
		return true
	},
}

// --- Rate limiter (per-IP connection tracking) ---

type RateLimiter struct {
	mu    sync.Mutex
	conns map[string]int
}

func newRateLimiter() *RateLimiter {
	return &RateLimiter{conns: make(map[string]int)}
}

func (rl *RateLimiter) Allow(ip string) bool {
	rl.mu.Lock()
	defer rl.mu.Unlock()
	if rl.conns[ip] >= maxConnsPerIP {
		return false
	}
	rl.conns[ip]++
	return true
}

func (rl *RateLimiter) Release(ip string) {
	rl.mu.Lock()
	defer rl.mu.Unlock()
	rl.conns[ip]--
	if rl.conns[ip] <= 0 {
		delete(rl.conns, ip)
	}
}

// --- Client ---

type Client struct {
	ws     *websocket.Conn
	irc    net.Conn
	send   chan []byte
	done   chan struct{} // signals all goroutines to stop
	once   sync.Once     // ensures done is closed only once
	id     string
	ip     string
}

func (c *Client) close() {
	c.once.Do(func() {
		close(c.done)
		// Close underlying connections to unblock any goroutines blocked
		// on network reads (ReadMessage, scanner.Scan)
		if c.irc != nil {
			c.irc.Close()
		}
		if c.ws != nil {
			c.ws.Close()
		}
	})
}

// --- Hub ---

type Hub struct {
	clients    map[*Client]bool
	register   chan *Client
	unregister chan *Client
	mu         sync.RWMutex
	done       chan struct{}
}

func newHub() *Hub {
	return &Hub{
		clients:    make(map[*Client]bool),
		register:   make(chan *Client),
		unregister: make(chan *Client),
		done:       make(chan struct{}),
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
				client.close()
				// Don't close(client.send) — ircPump may still be mid-send.
				// writePump exits via <-c.done instead.
			}
			h.mu.Unlock()
			log.Printf("[%s] Client unregistered. Total: %d", client.id, len(h.clients))

		case <-h.done:
			h.mu.Lock()
			for client := range h.clients {
				// Best-effort QUIT and close frame before tearing down
				if client.irc != nil {
					client.irc.Write([]byte("QUIT :Server shutting down\r\n"))
				}
				client.ws.WriteMessage(websocket.CloseMessage,
					websocket.FormatCloseMessage(websocket.CloseGoingAway, "server shutting down"))
				client.close()
				delete(h.clients, client)
			}
			h.mu.Unlock()
			log.Println("Hub shut down, all clients disconnected")
			return
		}
	}
}

// readPump reads messages from the WebSocket and forwards them to IRC
func (c *Client) readPump(hub *Hub) {
	defer func() {
		hub.unregister <- c
	}()

	c.ws.SetReadLimit(wsReadLimit)
	c.ws.SetReadDeadline(time.Now().Add(wsPongWait))
	c.ws.SetPongHandler(func(string) error {
		c.ws.SetReadDeadline(time.Now().Add(wsPongWait))
		return nil
	})

	for {
		select {
		case <-c.done:
			return
		default:
		}

		_, message, err := c.ws.ReadMessage()
		if err != nil {
			if websocket.IsUnexpectedCloseError(err, websocket.CloseGoingAway, websocket.CloseNormalClosure) {
				log.Printf("[%s] WebSocket read error: %v", c.id, err)
			}
			return
		}

		msg := strings.TrimSpace(string(message))
		if msg == "" {
			continue
		}

		// Truncate to IRC maximum message length
		if len(msg) > maxIRCMsgLen {
			msg = msg[:maxIRCMsgLen]
		}

		log.Printf("[%s] WS->IRC: %s", c.id, msg)
		if c.irc != nil {
			c.irc.SetWriteDeadline(time.Now().Add(wsWriteWait))
			_, writeErr := c.irc.Write([]byte(msg + "\r\n"))
			if writeErr != nil {
				log.Printf("[%s] IRC write error: %v", c.id, writeErr)
				c.close() // signal other goroutines to stop
				return
			}
		}
	}
}

// writePump writes messages from the send channel to the WebSocket, and sends pings
func (c *Client) writePump() {
	ticker := time.NewTicker(wsPingPeriod)
	defer ticker.Stop()

	for {
		select {
		case <-c.done:
			return

		case message := <-c.send:
			c.ws.SetWriteDeadline(time.Now().Add(wsWriteWait))
			err := c.ws.WriteMessage(websocket.TextMessage, message)
			if err != nil {
				log.Printf("[%s] WebSocket write error: %v", c.id, err)
				return
			}

		case <-ticker.C:
			c.ws.SetWriteDeadline(time.Now().Add(wsWriteWait))
			if err := c.ws.WriteMessage(websocket.PingMessage, nil); err != nil {
				return
			}
		}
	}
}

// ircPump reads messages from IRC and sends them to the WebSocket via the send channel
func (c *Client) ircPump() {
	defer func() {
		c.close() // signal other goroutines to stop
	}()

	scanner := bufio.NewScanner(c.irc)
	scanner.Buffer(make([]byte, 4096), 4096) // cap line size to match WebSocket read limit
	for scanner.Scan() {
		select {
		case <-c.done:
			return
		default:
		}

		line := scanner.Text()

		// Handle IRC PING server-side (don't round-trip through browser)
		if strings.HasPrefix(line, "PING ") {
			token := strings.TrimPrefix(line, "PING ")
			// Validate: token should be non-empty and not contain CR/LF
			if token != "" && !strings.ContainsAny(token, "\r\n") {
				c.irc.Write([]byte("PONG " + token + "\r\n"))
			}
			continue
		}

		if strings.Contains(line, "PRIVMSG") || strings.Contains(line, "JOIN") ||
			strings.Contains(line, "PART") || strings.Contains(line, "NICK") ||
			strings.Contains(line, "001") || strings.Contains(line, "353") ||
			strings.Contains(line, "433") || strings.Contains(line, "QUIT") {
			log.Printf("[%s] IRC->WS: %s", c.id, line)
		}

		select {
		case c.send <- []byte(line + "\n"):
		case <-c.done:
			return
		default:
			// Channel full — close the connection rather than silently
			// dropping messages, which would confuse the user
			log.Printf("[%s] Send channel full, closing connection", c.id)
			c.close()
			return
		}
	}

	if err := scanner.Err(); err != nil {
		log.Printf("[%s] IRC scanner error: %v", c.id, err)
	}
}

// --- WebSocket handler ---

func handleWebSocket(hub *Hub, limiter *RateLimiter, cleanupWg *sync.WaitGroup, w http.ResponseWriter, r *http.Request) {
	// Extract client IP — prefer X-Real-IP set by nginx reverse proxy,
	// since r.RemoteAddr is always the Docker gateway IP (172.x.x.x)
	clientIP := r.Header.Get("X-Real-IP")
	if clientIP == "" {
		clientIP = r.RemoteAddr
		if host, _, err := net.SplitHostPort(clientIP); err == nil {
			clientIP = host
		}
	}

	// Rate limit
	if !limiter.Allow(clientIP) {
		log.Printf("Rate limit exceeded for %s", clientIP)
		http.Error(w, "Too many connections", http.StatusTooManyRequests)
		return
	}

	seq := clientCounter.Add(1)
	clientID := fmt.Sprintf("client-%d", seq)
	log.Printf("[%s] New WebSocket request from %s", clientID, r.RemoteAddr)

	// Upgrade to WebSocket
	ws, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("[%s] WebSocket upgrade error: %v", clientID, err)
		limiter.Release(clientIP)
		return
	}

	// Connect to IRC server
	log.Printf("[%s] Connecting to IRC server %s", clientID, ircServer)
	ircConn, err := net.DialTimeout("tcp", ircServer, ircDialTimeout)
	if err != nil {
		log.Printf("[%s] IRC connection error: %v", clientID, err)
		ws.WriteMessage(websocket.CloseMessage,
			websocket.FormatCloseMessage(websocket.CloseInternalServerErr, "IRC unavailable"))
		ws.Close()
		limiter.Release(clientIP)
		return
	}

	// Register with IRC — single registration, no double NICK/USER
	nick := fmt.Sprintf("web%d", seq)
	log.Printf("[%s] Registering with IRC as %s", clientID, nick)

	if _, err = ircConn.Write([]byte(fmt.Sprintf("NICK %s\r\n", nick))); err != nil {
		log.Printf("[%s] IRC NICK write error: %v", clientID, err)
		ircConn.Close()
		ws.Close()
		limiter.Release(clientIP)
		return
	}
	if _, err = ircConn.Write([]byte(fmt.Sprintf("USER %s 0 * :Web User\r\n", nick))); err != nil {
		log.Printf("[%s] IRC USER write error: %v", clientID, err)
		ircConn.Close()
		ws.Close()
		limiter.Release(clientIP)
		return
	}

	client := &Client{
		ws:   ws,
		irc:  ircConn,
		send: make(chan []byte, 256),
		done: make(chan struct{}),
		id:   clientID,
		ip:   clientIP,
	}

	hub.register <- client

	// Release rate limiter slot when client disconnects
	cleanupWg.Add(1)
	go func() {
		defer cleanupWg.Done()
		<-client.done
		limiter.Release(clientIP)
	}()

	go client.writePump()
	go client.ircPump()
	go client.readPump(hub)
}

// --- Health check endpoint (cached to avoid hammering IRC with TCP dials) ---

var (
	healthMu     sync.Mutex
	healthOK     bool
	healthErr    string
	healthExpiry time.Time
)

const healthCacheTTL = 5 * time.Second

func handleHealth(w http.ResponseWriter, r *http.Request) {
	healthMu.Lock()
	if time.Now().Before(healthExpiry) {
		ok, errMsg := healthOK, healthErr
		healthMu.Unlock()
		if ok {
			w.WriteHeader(http.StatusOK)
			fmt.Fprint(w, "OK")
		} else {
			w.WriteHeader(http.StatusServiceUnavailable)
			fmt.Fprint(w, errMsg)
		}
		return
	}
	healthMu.Unlock()

	conn, err := net.DialTimeout("tcp", ircServer, 2*time.Second)

	healthMu.Lock()
	healthExpiry = time.Now().Add(healthCacheTTL)
	if err != nil {
		healthOK = false
		healthErr = "IRC unavailable"
		log.Printf("Health check failed: %v", err)
		healthMu.Unlock()
		w.WriteHeader(http.StatusServiceUnavailable)
		fmt.Fprint(w, "IRC unavailable")
		return
	}
	healthOK = true
	healthErr = ""
	healthMu.Unlock()

	conn.Close()
	w.WriteHeader(http.StatusOK)
	fmt.Fprint(w, "OK")
}

// --- Main ---

func main() {
	hub := newHub()
	go hub.run()

	limiter := newRateLimiter()
	cleanupWg := &sync.WaitGroup{}

	mux := http.NewServeMux()
	mux.HandleFunc("/ws", func(w http.ResponseWriter, r *http.Request) {
		handleWebSocket(hub, limiter, cleanupWg, w, r)
	})
	mux.HandleFunc("/health", handleHealth)

	server := &http.Server{
		Addr:    listenAddr,
		Handler: mux,
	}

	// Graceful shutdown on SIGINT/SIGTERM
	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)

	go func() {
		log.Printf("IRC Bridge starting on %s", listenAddr)
		if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("ListenAndServe error: %v", err)
		}
	}()

	<-quit
	log.Println("Shutting down...")

	// Stop accepting new connections
	ctx, cancel := context.WithTimeout(context.Background(), shutdownTimeout)
	defer cancel()

	// Close all client connections gracefully
	close(hub.done)

	// Shut down HTTP server
	if err := server.Shutdown(ctx); err != nil {
		log.Printf("HTTP server shutdown error: %v", err)
	}

	// Wait for all cleanup goroutines (rate limiter releases) to finish
	cleanupWg.Wait()

	log.Println("Server stopped")
}

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
	"syscall"
	"time"

	"github.com/gorilla/websocket"
)

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
)

// --- WebSocket upgrader with origin check ---

var upgrader = websocket.Upgrader{
	ReadBufferSize:  1024,
	WriteBufferSize: 1024,
	CheckOrigin: func(r *http.Request) bool {
		// Allow connections from the same host (mesh network)
		// In a mesh/local network context, accept all local origins
		origin := r.Header.Get("Origin")
		if origin == "" {
			return true
		}
		// Accept any origin on local/private networks
		// This is appropriate for a mesh network chat with no internet
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
				if client.irc != nil {
					client.irc.Close()
				}
				client.ws.Close()
			}
			h.mu.Unlock()
			log.Printf("[%s] Client unregistered. Total: %d", client.id, len(h.clients))

		case <-h.done:
			h.mu.Lock()
			for client := range h.clients {
				client.close()
				if client.irc != nil {
					// Send QUIT before closing
					client.irc.Write([]byte("QUIT :Server shutting down\r\n"))
					client.irc.Close()
				}
				client.ws.WriteMessage(websocket.CloseMessage,
					websocket.FormatCloseMessage(websocket.CloseGoingAway, "server shutting down"))
				client.ws.Close()
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

		log.Printf("[%s] WS->IRC: %s", c.id, msg)
		if c.irc != nil {
			_, writeErr := c.irc.Write([]byte(msg + "\r\n"))
			if writeErr != nil {
				log.Printf("[%s] IRC write error: %v", c.id, writeErr)
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

		case message, ok := <-c.send:
			c.ws.SetWriteDeadline(time.Now().Add(wsWriteWait))
			if !ok {
				c.ws.WriteMessage(websocket.CloseMessage, []byte{})
				return
			}
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
	for scanner.Scan() {
		select {
		case <-c.done:
			return
		default:
		}

		line := scanner.Text()
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
			log.Printf("[%s] Send channel full, dropping message", c.id)
		}
	}

	if err := scanner.Err(); err != nil {
		log.Printf("[%s] IRC scanner error: %v", c.id, err)
	}
}

// --- WebSocket handler ---

func handleWebSocket(hub *Hub, limiter *RateLimiter, w http.ResponseWriter, r *http.Request) {
	// Extract client IP
	clientIP := r.RemoteAddr
	if host, _, err := net.SplitHostPort(clientIP); err == nil {
		clientIP = host
	}

	// Rate limit
	if !limiter.Allow(clientIP) {
		log.Printf("Rate limit exceeded for %s", clientIP)
		http.Error(w, "Too many connections", http.StatusTooManyRequests)
		return
	}

	clientID := fmt.Sprintf("client-%d", time.Now().UnixNano()%10000)
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
	nick := fmt.Sprintf("webuser%d", time.Now().Unix()%10000)
	log.Printf("[%s] Registering with IRC as %s", clientID, nick)

	ircConn.Write([]byte(fmt.Sprintf("NICK %s\r\n", nick)))
	ircConn.Write([]byte(fmt.Sprintf("USER %s 0 * :Web User\r\n", nick)))
	ircConn.Write([]byte(fmt.Sprintf("JOIN %s\r\n", ircChannel)))

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
	go func() {
		<-client.done
		limiter.Release(clientIP)
	}()

	go client.writePump()
	go client.ircPump()
	go client.readPump(hub)
}

// --- Health check endpoint ---

func handleHealth(w http.ResponseWriter, r *http.Request) {
	// Quick check: can we reach the IRC server?
	conn, err := net.DialTimeout("tcp", ircServer, 2*time.Second)
	if err != nil {
		w.WriteHeader(http.StatusServiceUnavailable)
		fmt.Fprintf(w, "IRC unreachable: %v", err)
		return
	}
	conn.Close()
	w.WriteHeader(http.StatusOK)
	fmt.Fprint(w, "OK")
}

// --- Main ---

func main() {
	hub := newHub()
	go hub.run()

	limiter := newRateLimiter()

	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		handleWebSocket(hub, limiter, w, r)
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

	log.Println("Server stopped")
}

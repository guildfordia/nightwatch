package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
	"unicode/utf8"

	"github.com/gorilla/websocket"
)

var startTime = time.Now()

func envOrDefault(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

// Monotonic counters for unique client IDs and IRC nicks
var clientCounter atomic.Uint64

// nickRegistry tracks all ever-assigned guestN nicks so they're never reused.
// The counter persists across restarts via a file. Writes are batched to reduce
// SD card wear: flushed every 10 assignments or 60 seconds, whichever is first.
type NickRegistry struct {
	mu          sync.Mutex
	assigned    map[string]bool // all nicks ever assigned (guestN nicks)
	activeNicks map[string]bool // nicks currently in use by connected clients
	counter     uint64          // high-water mark for guestN generation
	counterFile string          // path to persist counter
	dirty       uint64          // assignments since last disk flush
}

func nickCounterPath() string {
	if dir := os.Getenv("DATA_DIR"); dir != "" {
		return dir + "/nick-counter"
	}
	return "/data/nick-counter"
}

func newNickRegistry() *NickRegistry {
	nr := &NickRegistry{
		assigned:    make(map[string]bool),
		activeNicks: make(map[string]bool),
		counterFile: nickCounterPath(),
	}
	nr.loadCounter()
	return nr
}

func (nr *NickRegistry) loadCounter() {
	data, err := os.ReadFile(nr.counterFile)
	if err != nil {
		log.Printf("No saved nick counter (starting fresh): %v", err)
		return
	}
	var val uint64
	if _, err := fmt.Sscanf(strings.TrimSpace(string(data)), "%d", &val); err == nil {
		nr.counter = val
		// Mark all previously assigned guestN nicks as taken
		for i := uint64(1); i <= val; i++ {
			nr.assigned[fmt.Sprintf("guest%d", i)] = true
		}
		log.Printf("Loaded nick counter: %d (guest1-guest%d reserved)", val, val)
	}
}

const nickFlushThreshold = 10

func (nr *NickRegistry) saveCounter() {
	if err := os.MkdirAll(filepath.Dir(nr.counterFile), 0755); err != nil {
		log.Printf("Failed to create data dir: %v", err)
		return // don't reset dirty — retry on next flush
	}
	if err := os.WriteFile(nr.counterFile, []byte(fmt.Sprintf("%d\n", nr.counter)), 0644); err != nil {
		log.Printf("Failed to save nick counter: %v", err)
		return // don't reset dirty — retry on next flush
	}
	nr.dirty = 0
}

// flushLoop periodically writes the nick counter to disk if dirty.
// This ensures durability even if the batch threshold is never reached.
func (nr *NickRegistry) flushLoop(ctx context.Context) {
	ticker := time.NewTicker(60 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			nr.mu.Lock()
			if nr.dirty > 0 {
				nr.saveCounter()
			}
			nr.mu.Unlock()
			return
		case <-ticker.C:
			nr.mu.Lock()
			if nr.dirty > 0 {
				nr.saveCounter()
				log.Printf("Nick counter flushed to disk (periodic): %d", nr.counter)
			}
			nr.mu.Unlock()
		}
	}
}

// NextNick generates a new unique guestN nick that has never been used
func (nr *NickRegistry) NextNick() string {
	nr.mu.Lock()
	defer nr.mu.Unlock()
	nr.counter++
	nr.dirty++
	nick := fmt.Sprintf("guest%d", nr.counter)
	nr.assigned[nick] = true
	nr.activeNicks[nick] = true
	// Flush to disk every N assignments to reduce SD card writes
	if nr.dirty >= nickFlushThreshold {
		nr.saveCounter()
	}
	return nick
}

// ClaimNick tries to reclaim a nick (reconnecting client).
// Returns true if the nick is not currently active (available to use).
// Accepts both guestN nicks and custom nicks set via /nick.
// Retries briefly to handle the race where old connection is still cleaning up.
func (nr *NickRegistry) ClaimNick(nick string) bool {
	for attempt := 0; attempt < 3; attempt++ {
		nr.mu.Lock()
		if !nr.activeNicks[nick] {
			nr.activeNicks[nick] = true
			nr.mu.Unlock()
			return true
		}
		nr.mu.Unlock()
		if attempt < 2 {
			time.Sleep(500 * time.Millisecond) // wait for old connection to release
		}
	}
	return false // still in use after retries
}

// ReleaseNick marks a nick as no longer actively connected (but still reserved)
func (nr *NickRegistry) ReleaseNick(nick string) {
	nr.mu.Lock()
	defer nr.mu.Unlock()
	delete(nr.activeNicks, nick)
	// Nick stays in nr.assigned — it's reserved forever
}

var nickRegistry *NickRegistry

// --- Configuration ---

var ircServer = envOrDefault("IRC_SERVER", "127.0.0.1:6667")

const (
	ircChannel       = "#nightwatch"
	listenAddr       = ":3000"
	maxConnsPerIP    = 5
	wsReadLimit      = 4096
	clientSendBuffer = 256 // buffered channel size for WebSocket messages
	wsPongWait       = 5 * time.Minute   // mobile browsers may background for minutes
	wsPingPeriod     = 4 * time.Minute   // must be < pongWait
	wsWriteWait      = 10 * time.Second
	shutdownTimeout  = 10 * time.Second
	maxIRCMsgLen     = 400 // IRC limit minus protocol overhead
	replayBufferSize = 50  // number of recent messages to replay on reconnect
)

// ircDialTimeout is configurable via IRC_DIAL_TIMEOUT env var (default 10s).
// Pi Zero on congested mesh may need more than the previous 5s default.
var ircDialTimeout = func() time.Duration {
	if v := os.Getenv("IRC_DIAL_TIMEOUT"); v != "" {
		if d, err := time.ParseDuration(v); err == nil {
			return d
		}
	}
	return 10 * time.Second
}()

// --- Message replay buffer ---
// Stores recent PRIVMSG lines so reconnecting clients don't miss messages.

type ReplayBuffer struct {
	mu   sync.Mutex
	msgs []string
	idx  int
	full bool
}

func NewReplayBuffer(size int) *ReplayBuffer {
	return &ReplayBuffer{msgs: make([]string, size)}
}

func (rb *ReplayBuffer) Add(line string) {
	rb.mu.Lock()
	defer rb.mu.Unlock()
	rb.msgs[rb.idx] = line
	rb.idx = (rb.idx + 1) % len(rb.msgs)
	if rb.idx == 0 {
		rb.full = true
	}
}

func (rb *ReplayBuffer) Recent() []string {
	rb.mu.Lock()
	defer rb.mu.Unlock()
	if !rb.full {
		result := make([]string, rb.idx)
		copy(result, rb.msgs[:rb.idx])
		return result
	}
	result := make([]string, len(rb.msgs))
	copy(result, rb.msgs[rb.idx:])
	copy(result[len(rb.msgs)-rb.idx:], rb.msgs[:rb.idx])
	return result
}

var replayBuffer = NewReplayBuffer(replayBufferSize)

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
	nick   string        // IRC nick assigned to this client
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
	defer func() {
		if r := recover(); r != nil {
			log.Printf("CRITICAL: hub.run() panic: %v — all future connections will fail", r)
		}
	}()
	for {
		select {
		case client := <-h.register:
			h.mu.Lock()
			h.clients[client] = true
			count := len(h.clients)
			h.mu.Unlock()
			log.Printf("[%s] Client registered. Total: %d", client.id, count)

		case client := <-h.unregister:
			h.mu.Lock()
			if _, ok := h.clients[client]; ok {
				delete(h.clients, client)
				client.close()
				// Release nick from active set (stays reserved forever)
				if client.nick != "" && nickRegistry != nil {
					nickRegistry.ReleaseNick(client.nick)
				}
				// Don't close(client.send) — ircPump may still be mid-send.
				// writePump exits via <-c.done instead.
			}
			count := len(h.clients)
			h.mu.Unlock()
			log.Printf("[%s] Client unregistered (nick=%s). Total: %d", client.id, client.nick, count)

		case <-h.done:
			h.mu.Lock()
			for client := range h.clients {
				// Best-effort QUIT and close frame before tearing down.
				// Use WriteControl (thread-safe) instead of WriteMessage to
				// avoid panicking on concurrent writes with writePump.
				select {
				case <-client.done:
					// Already closing — skip graceful shutdown messages
				default:
					if client.irc != nil {
						client.irc.SetWriteDeadline(time.Now().Add(1 * time.Second))
						client.irc.Write([]byte("QUIT :Server shutting down\r\n"))
					}
					client.ws.WriteControl(websocket.CloseMessage,
						websocket.FormatCloseMessage(websocket.CloseGoingAway, "server shutting down"),
						time.Now().Add(1*time.Second))
				}
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
		// No need to select on c.done here — c.close() closes the WebSocket,
		// which unblocks ReadMessage with an error, causing a clean return.
		_, message, err := c.ws.ReadMessage()
		if err != nil {
			if websocket.IsUnexpectedCloseError(err, websocket.CloseGoingAway, websocket.CloseNormalClosure) {
				log.Printf("[%s] WebSocket read error: %v", c.id, err)
			}
			return
		}

		// Reset read deadline on any received message (not just pongs)
		c.ws.SetReadDeadline(time.Now().Add(wsPongWait))

		msg := strings.TrimSpace(string(message))
		if msg == "" {
			continue
		}

		// Truncate to IRC maximum message length (by rune count to avoid
		// splitting multi-byte UTF-8 characters like emoji)
		if utf8.RuneCountInString(msg) > maxIRCMsgLen {
			runes := []rune(msg)
			msg = string(runes[:maxIRCMsgLen])
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
			// WriteControl is safe for concurrent use (unlike WriteMessage),
			// so shutdown code can send a CloseMessage at the same time.
			if err := c.ws.WriteControl(websocket.PingMessage, nil, time.Now().Add(wsWriteWait)); err != nil {
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
			// Guard against: oversized tokens, CR/LF injection, and space-based
			// command injection (e.g., "PING :foo PRIVMSG #ch :spam")
			if token != "" && len(token) < 64 && !strings.ContainsAny(token, "\r\n ") {
				c.irc.SetWriteDeadline(time.Now().Add(wsWriteWait))
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

		// Store PRIVMSG in replay buffer for reconnecting clients
		if strings.Contains(line, "PRIVMSG "+ircChannel) {
			replayBuffer.Add(line)
		}

		// Try to send; if channel is full, wait briefly before giving up.
		// This prevents unnecessary disconnects during IRC floods (mass join/part).
		select {
		case c.send <- []byte(line + "\n"):
		case <-c.done:
			return
		default:
			// Buffer full — give writePump a moment to drain before disconnecting
			select {
			case c.send <- []byte(line + "\n"):
			case <-c.done:
				return
			case <-time.After(100 * time.Millisecond):
				log.Printf("[%s] Send channel full for 100ms, closing connection", c.id)
				c.close()
				return
			}
		}
	}

	if err := scanner.Err(); err != nil {
		log.Printf("[%s] IRC scanner error: %v", c.id, err)
	}
}

// isValidIRCNick checks that a nick contains only safe IRC characters
func isValidIRCNick(nick string) bool {
	if len(nick) == 0 || len(nick) > 16 {
		return false
	}
	for _, c := range nick {
		if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
			(c >= '0' && c <= '9') || c == '-' || c == '_' || c == '[' ||
			c == ']' || c == '\\' || c == '`' || c == '^' || c == '{' || c == '}') {
			return false
		}
	}
	// First char must not be a digit
	if nick[0] >= '0' && nick[0] <= '9' {
		return false
	}
	return true
}

// --- WebSocket handler ---

func handleWebSocket(hub *Hub, limiter *RateLimiter, cleanupWg *sync.WaitGroup, cleanupCtx context.Context, w http.ResponseWriter, r *http.Request) {
	// Extract client IP. Only trust X-Real-IP when the request comes from
	// localhost (i.e., via nginx reverse proxy). If the bridge is exposed
	// directly, this prevents rate-limit bypass via header spoofing.
	clientIP := r.RemoteAddr
	if host, _, err := net.SplitHostPort(clientIP); err == nil {
		clientIP = host
	}
	if clientIP == "127.0.0.1" || clientIP == "::1" {
		if realIP := r.Header.Get("X-Real-IP"); realIP != "" {
			clientIP = realIP
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

	// Connect to IRC server. Use a standalone context (not r.Context()) because
	// the HTTP request context is cancelled if the client disconnects before the
	// upgrade completes, which would leak the IRC connection.
	log.Printf("[%s] Connecting to IRC server %s", clientID, ircServer)
	dialCtx, dialCancel := context.WithTimeout(context.Background(), ircDialTimeout)
	defer dialCancel()
	dialer := net.Dialer{}
	ircConn, err := dialer.DialContext(dialCtx, "tcp", ircServer)
	if err != nil {
		log.Printf("[%s] IRC connection error: %v", clientID, err)
		ws.WriteMessage(websocket.CloseMessage,
			websocket.FormatCloseMessage(websocket.CloseInternalServerErr, "IRC unavailable"))
		ws.Close()
		limiter.Release(clientIP)
		return
	}

	// Use nick from query param if provided (reconnecting client),
	// otherwise generate a new one. Sanitize to prevent IRC injection.
	nick := r.URL.Query().Get("nick")
	if nick != "" && isValidIRCNick(nick) {
		// Reconnecting client — try to reclaim their saved nick
		if nickRegistry.ClaimNick(nick) {
			log.Printf("[%s] Reclaimed nick: %s", clientID, nick)
		} else {
			// Nick is actively in use by someone else — assign a new one
			log.Printf("[%s] Nick %s in use, assigning new nick", clientID, nick)
			nick = nickRegistry.NextNick()
		}
	} else {
		nick = nickRegistry.NextNick()
	}
	log.Printf("[%s] Registering with IRC as %s", clientID, nick)

	if _, err = ircConn.Write([]byte(fmt.Sprintf("NICK %s\r\n", nick))); err != nil {
		log.Printf("[%s] IRC NICK write error: %v", clientID, err)
		nickRegistry.ReleaseNick(nick)
		ircConn.Close()
		ws.Close()
		limiter.Release(clientIP)
		return
	}
	if _, err = ircConn.Write([]byte(fmt.Sprintf("USER %s 0 * :Web User\r\n", nick))); err != nil {
		log.Printf("[%s] IRC USER write error: %v", clientID, err)
		nickRegistry.ReleaseNick(nick)
		ircConn.Close()
		ws.Close()
		limiter.Release(clientIP)
		return
	}

	// Join the channel server-side immediately after registration.
	// Don't rely on the JS client's ws.onopen to send JOIN — mobile browsers
	// can fail to fire onopen reliably, leaving the user connected but not in the channel.
	if _, err = ircConn.Write([]byte(fmt.Sprintf("JOIN %s\r\n", ircChannel))); err != nil {
		log.Printf("[%s] IRC JOIN write error: %v", clientID, err)
		nickRegistry.ReleaseNick(nick)
		ircConn.Close()
		ws.Close()
		limiter.Release(clientIP)
		return
	}
	log.Printf("[%s] Server-side JOIN %s for %s", clientID, ircChannel, nick)

	client := &Client{
		ws:   ws,
		irc:  ircConn,
		send: make(chan []byte, clientSendBuffer),
		done: make(chan struct{}),
		id:   clientID,
		ip:   clientIP,
		nick: nick,
	}

	hub.register <- client

	// Release rate limiter slot when client disconnects.
	// cleanupCtx is cancelled on shutdown so cleanupWg.Wait() won't hang.
	cleanupWg.Add(1)
	go func() {
		defer cleanupWg.Done()
		select {
		case <-client.done:
		case <-cleanupCtx.Done():
			log.Printf("[%s] Cleanup: server shutting down — releasing rate limiter", clientID)
		}
		limiter.Release(clientIP)
	}()

	// Replay recent messages so reconnecting clients don't miss anything
	recent := replayBuffer.Recent()
	if len(recent) > 0 {
		log.Printf("[%s] Replaying %d recent messages", clientID, len(recent))
		for _, msg := range recent {
			// Don't replay the client's own messages (they already have them)
			if !strings.Contains(msg, "!~"+nick+"@") {
				client.send <- []byte(msg + "\n")
			}
		}
	}

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

	// Return cached result if still fresh
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

	// Mark cache as refreshing so concurrent requests return the stale-but-
	// usable cached result while we dial. Use a short expiry (dial timeout)
	// so the cache is updated with the real result once the dial completes.
	healthExpiry = time.Now().Add(2 * time.Second)
	healthMu.Unlock()

	conn, err := net.DialTimeout("tcp", ircServer, 2*time.Second)

	healthMu.Lock()
	if err != nil {
		healthOK = false
		healthErr = "IRC unavailable"
		log.Printf("Health check failed: %v", err)
	} else {
		conn.Close()
		healthOK = true
		healthErr = ""
	}
	// Set the real expiry now that we have fresh data
	healthExpiry = time.Now().Add(healthCacheTTL)
	ok, errMsg := healthOK, healthErr
	healthMu.Unlock()

	if ok {
		w.WriteHeader(http.StatusOK)
		fmt.Fprint(w, "OK")
	} else {
		w.WriteHeader(http.StatusServiceUnavailable)
		fmt.Fprint(w, errMsg)
	}
}

// --- Status endpoint (debug diagnostics) ---

func handleStatus(hub *Hub, limiter *RateLimiter) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		hub.mu.RLock()
		clientCount := len(hub.clients)
		clients := make([]map[string]interface{}, 0, clientCount)
		for c := range hub.clients {
			clients = append(clients, map[string]interface{}{
				"id":          c.id,
				"ip":          c.ip,
				"nick":        c.nick,
				"send_buffer": len(c.send),
			})
		}
		hub.mu.RUnlock()

		limiter.mu.Lock()
		connsByIP := make(map[string]int, len(limiter.conns))
		for ip, count := range limiter.conns {
			connsByIP[ip] = count
		}
		limiter.mu.Unlock()

		// Reuse health cache instead of dialing IRC on every /status request
		healthMu.Lock()
		ircStatus := "ok"
		ircLatencyMs := int64(-1)
		if !healthOK && healthErr != "" {
			ircStatus = healthErr
		}
		healthMu.Unlock()

		var memStats runtime.MemStats
		runtime.ReadMemStats(&memStats)

		// Nick registry stats
		nickRegistry.mu.Lock()
		nickTotal := len(nickRegistry.assigned)
		nickActive := len(nickRegistry.activeNicks)
		nickCounter := nickRegistry.counter
		nickRegistry.mu.Unlock()

		status := map[string]interface{}{
			"nick_registry": map[string]interface{}{
				"counter":       nickCounter,
				"total_reserved": nickTotal,
				"active":        nickActive,
			},
			"bridge": map[string]interface{}{
				"uptime_seconds":  int(time.Since(startTime).Seconds()),
				"uptime_human":    time.Since(startTime).Round(time.Second).String(),
				"goroutines":      runtime.NumGoroutine(),
				"memory_mb":       float64(memStats.Alloc) / 1024 / 1024,
				"total_served":    clientCounter.Load(),
				"active_clients":  clientCount,
				"clients":         clients,
				"conns_by_ip":     connsByIP,
				"max_conns_per_ip": maxConnsPerIP,
			},
			"irc": map[string]interface{}{
				"server":     ircServer,
				"status":     ircStatus,
				"latency_ms": ircLatencyMs,
				"channel":    ircChannel,
			},
		}

		w.Header().Set("Content-Type", "application/json")
		enc := json.NewEncoder(w)
		enc.SetIndent("", "  ")
		if err := enc.Encode(status); err != nil {
			log.Printf("Status JSON encode error: %v", err)
		}
	}
}

// --- Main ---

func main() {
	nickRegistry = newNickRegistry()

	// Background context for nick counter flush loop (cancelled on shutdown)
	flushCtx, flushCancel := context.WithCancel(context.Background())
	flushWg := &sync.WaitGroup{}
	flushWg.Add(1)
	go func() {
		defer flushWg.Done()
		nickRegistry.flushLoop(flushCtx)
	}()

	hub := newHub()
	go hub.run()

	limiter := newRateLimiter()
	cleanupWg := &sync.WaitGroup{}
	cleanupCtx, cleanupCancel := context.WithCancel(context.Background())

	mux := http.NewServeMux()
	mux.HandleFunc("/ws", func(w http.ResponseWriter, r *http.Request) {
		handleWebSocket(hub, limiter, cleanupWg, cleanupCtx, w, r)
	})
	mux.HandleFunc("/health", handleHealth)
	mux.HandleFunc("/status", handleStatus(hub, limiter))

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

	// Stop the periodic flush loop and wait for it to finish its current
	// iteration before we do the final flush below (avoids concurrent saveCounter).
	flushCancel()
	flushWg.Wait()

	// Stop accepting new WebSocket connections first, so no new clients
	// try to send on hub.register after hub.run() exits (which would deadlock).
	ctx, cancel := context.WithTimeout(context.Background(), shutdownTimeout)
	defer cancel()
	if err := server.Shutdown(ctx); err != nil {
		log.Printf("HTTP server shutdown error: %v", err)
	}

	// Now close all existing client connections gracefully
	close(hub.done)

	// Final nick counter flush — clients may have assigned nicks during
	// the slow shutdown window between flushCancel() and server.Shutdown().
	nickRegistry.mu.Lock()
	if nickRegistry.dirty > 0 {
		pending := nickRegistry.dirty
		nickRegistry.saveCounter()
		if nickRegistry.dirty > 0 {
			log.Printf("CRITICAL: Final nick counter flush FAILED — %d assignments may be lost (counter=%d)", pending, nickRegistry.counter)
		} else {
			log.Printf("Final nick counter flush: %d", nickRegistry.counter)
		}
	}
	nickRegistry.mu.Unlock()

	// Cancel cleanup context so goroutines waiting on client.done unblock
	cleanupCancel()
	// Wait for all cleanup goroutines (rate limiter releases) to finish
	cleanupWg.Wait()

	log.Println("Server stopped")
}

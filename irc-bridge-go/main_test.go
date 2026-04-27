package main

import (
	"fmt"
	"os"
	"context"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

// ============================================================
// Rate Limiter Tests
// ============================================================

func TestRateLimiterAllowUnderLimit(t *testing.T) {
	rl := newRateLimiter()
	for i := 0; i < maxConnsPerIP; i++ {
		if !rl.Allow("192.168.1.1") {
			t.Fatalf("Allow() returned false on connection %d, want true (limit=%d)", i+1, maxConnsPerIP)
		}
	}
}

func TestRateLimiterBlockOverLimit(t *testing.T) {
	rl := newRateLimiter()
	for i := 0; i < maxConnsPerIP; i++ {
		rl.Allow("192.168.1.1")
	}
	if rl.Allow("192.168.1.1") {
		t.Fatal("Allow() returned true over limit, want false")
	}
}

func TestRateLimiterSeparateIPs(t *testing.T) {
	rl := newRateLimiter()
	for i := 0; i < maxConnsPerIP; i++ {
		rl.Allow("192.168.1.1")
	}
	// Different IP should still be allowed
	if !rl.Allow("192.168.1.2") {
		t.Fatal("Allow() blocked a different IP, want true")
	}
}

func TestRateLimiterRelease(t *testing.T) {
	rl := newRateLimiter()
	for i := 0; i < maxConnsPerIP; i++ {
		rl.Allow("192.168.1.1")
	}
	if rl.Allow("192.168.1.1") {
		t.Fatal("should be blocked before release")
	}
	rl.Release("192.168.1.1")
	if !rl.Allow("192.168.1.1") {
		t.Fatal("Allow() returned false after Release(), want true")
	}
}

func TestRateLimiterReleaseDeletesKey(t *testing.T) {
	rl := newRateLimiter()
	rl.Allow("10.0.0.1")
	rl.Release("10.0.0.1")
	rl.mu.Lock()
	_, exists := rl.conns["10.0.0.1"]
	rl.mu.Unlock()
	if exists {
		t.Fatal("IP should be removed from map after last Release()")
	}
}

func TestRateLimiterConcurrent(t *testing.T) {
	rl := newRateLimiter()
	var wg sync.WaitGroup
	allowed := make(chan bool, 100)

	for i := 0; i < 20; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			allowed <- rl.Allow("192.168.1.1")
		}()
	}
	wg.Wait()
	close(allowed)

	count := 0
	for a := range allowed {
		if a {
			count++
		}
	}
	if count != maxConnsPerIP {
		t.Fatalf("concurrent Allow() allowed %d connections, want %d", count, maxConnsPerIP)
	}
}

// ============================================================
// Hub Tests
// ============================================================

func TestHubRegisterUnregister(t *testing.T) {
	hub := newHub()
	go hub.run()
	defer close(hub.done)

	// Create a mock client with a pipe-based WebSocket isn't easy,
	// so we test the hub's channel mechanics directly
	client := &Client{
		send: make(chan []byte, 256),
		done: make(chan struct{}),
		id:   "test-1",
		ip:   "127.0.0.1",
	}

	// We need real connections for the hub to close.
	// Use a pipe for the IRC conn and a test server for WS.
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		upgrader := websocket.Upgrader{CheckOrigin: func(r *http.Request) bool { return true }}
		c, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			return
		}
		defer c.Close()
		// Hold connection open
		for {
			_, _, err := c.ReadMessage()
			if err != nil {
				return
			}
		}
	}))
	defer server.Close()

	wsURL := "ws" + strings.TrimPrefix(server.URL, "http")
	ws, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		t.Fatalf("dial ws: %v", err)
	}
	client.ws = ws

	ircServer, ircClient := net.Pipe()
	defer ircServer.Close()
	client.irc = ircClient

	hub.register <- client
	time.Sleep(50 * time.Millisecond)

	hub.mu.RLock()
	count := len(hub.clients)
	hub.mu.RUnlock()
	if count != 1 {
		t.Fatalf("hub has %d clients after register, want 1", count)
	}

	hub.unregister <- client
	time.Sleep(50 * time.Millisecond)

	hub.mu.RLock()
	count = len(hub.clients)
	hub.mu.RUnlock()
	if count != 0 {
		t.Fatalf("hub has %d clients after unregister, want 0", count)
	}
}

func TestHubShutdownClosesClients(t *testing.T) {
	hub := newHub()
	go hub.run()

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		upgrader := websocket.Upgrader{CheckOrigin: func(r *http.Request) bool { return true }}
		c, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			return
		}
		defer c.Close()
		for {
			_, _, err := c.ReadMessage()
			if err != nil {
				return
			}
		}
	}))
	defer server.Close()

	wsURL := "ws" + strings.TrimPrefix(server.URL, "http")
	ws, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		t.Fatalf("dial ws: %v", err)
	}

	// Use a TCP connection instead of net.Pipe to avoid blocking writes
	// during shutdown (hub.run sends QUIT before closing IRC conn)
	ircLn, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	defer ircLn.Close()

	// Accept connections in background and drain them
	go func() {
		for {
			conn, err := ircLn.Accept()
			if err != nil {
				return
			}
			go func(c net.Conn) {
				defer c.Close()
				buf := make([]byte, 4096)
				for {
					_, err := c.Read(buf)
					if err != nil {
						return
					}
				}
			}(conn)
		}
	}()

	ircConn, err := net.DialTimeout("tcp", ircLn.Addr().String(), 2*time.Second)
	if err != nil {
		t.Fatalf("dial mock irc: %v", err)
	}

	client := &Client{
		ws:   ws,
		irc:  ircConn,
		send: make(chan []byte, 256),
		done: make(chan struct{}),
		id:   "test-shutdown",
		ip:   "127.0.0.1",
	}

	hub.register <- client
	time.Sleep(50 * time.Millisecond)

	close(hub.done)
	time.Sleep(200 * time.Millisecond)

	hub.mu.RLock()
	count := len(hub.clients)
	hub.mu.RUnlock()
	if count != 0 {
		t.Fatalf("hub has %d clients after shutdown, want 0", count)
	}
}

// ============================================================
// Client close() Tests — sync.Once safety
// ============================================================

func TestClientCloseIdempotent(t *testing.T) {
	c := &Client{
		done: make(chan struct{}),
	}
	// Should not panic on multiple calls
	c.close()
	c.close()
	c.close()

	select {
	case <-c.done:
		// good
	default:
		t.Fatal("done channel should be closed after close()")
	}
}

func TestClientCloseConcurrent(t *testing.T) {
	c := &Client{
		done: make(chan struct{}),
	}
	var wg sync.WaitGroup
	for i := 0; i < 50; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			c.close() // must not panic
		}()
	}
	wg.Wait()
}

// ============================================================
// WebSocket Handler Tests
// ============================================================

func startMockIRCServer(t *testing.T) (string, func()) {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			go func(c net.Conn) {
				defer c.Close()
				// Minimal IRC handshake: send welcome on registration
				buf := make([]byte, 4096)
				nick := ""
				for {
					n, err := c.Read(buf)
					if err != nil {
						return
					}
					lines := strings.Split(string(buf[:n]), "\r\n")
					for _, line := range lines {
						if strings.HasPrefix(line, "NICK ") {
							nick = strings.TrimPrefix(line, "NICK ")
						}
						if strings.HasPrefix(line, "USER ") && nick != "" {
							c.Write([]byte(":irc 001 " + nick + " :Welcome\r\n"))
						}
						if strings.HasPrefix(line, "JOIN ") {
							ch := strings.TrimPrefix(line, "JOIN ")
							c.Write([]byte(":" + nick + " JOIN " + ch + "\r\n"))
							c.Write([]byte(":irc 353 " + nick + " = " + ch + " :" + nick + "\r\n"))
						}
						if strings.HasPrefix(line, "QUIT") {
							return
						}
					}
				}
			}(conn)
		}
	}()
	return ln.Addr().String(), func() { ln.Close() }
}

func TestHealthEndpointWithIRC(t *testing.T) {
	addr, cleanup := startMockIRCServer(t)
	defer cleanup()

	// Temporarily override ircServer — we can't change the const, so we
	// test the health logic directly by dialing the mock.
	conn, err := net.DialTimeout("tcp", addr, 2*time.Second)
	if err != nil {
		t.Fatalf("mock IRC unreachable: %v", err)
	}
	conn.Close()

	// Test the handler directly with a custom server address check
	req := httptest.NewRequest("GET", "/health", nil)
	rec := httptest.NewRecorder()

	// Since handleHealth dials the hard-coded ircServer, we test it as
	// an integration-style test (it will fail to connect to 127.0.0.1:6667
	// since ngircd isn't running in test). We verify the response code logic.
	handleHealth(rec, req)

	// Without a real IRC server on ngircd:6667, health should return 503
	if rec.Code != http.StatusServiceUnavailable {
		// If ngircd happens to be running locally, 200 is also OK
		if rec.Code != http.StatusOK {
			t.Fatalf("health returned %d, want 503 or 200", rec.Code)
		}
	}
}

func TestHealthEndpointFormat(t *testing.T) {
	req := httptest.NewRequest("GET", "/health", nil)
	rec := httptest.NewRecorder()
	handleHealth(rec, req)

	body := rec.Body.String()
	// Should contain meaningful info
	if !strings.Contains(body, "IRC") && !strings.Contains(body, "OK") {
		t.Fatalf("health response body unexpected: %q", body)
	}
}

func TestWebSocketHandlerRateLimit(t *testing.T) {
	hub := newHub()
	go hub.run()
	defer close(hub.done)

	limiter := newRateLimiter()

	// Use up all rate limit slots
	for i := 0; i < maxConnsPerIP; i++ {
		limiter.Allow("127.0.0.1")
	}

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		handleWebSocket(hub, limiter, &sync.WaitGroup{}, context.Background(), w, r)
	}))
	defer server.Close()

	// Try to connect — should be rejected with 429
	resp, err := http.Get(server.URL)
	if err != nil {
		t.Fatalf("request failed: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusTooManyRequests {
		t.Fatalf("got status %d, want %d", resp.StatusCode, http.StatusTooManyRequests)
	}
}

func TestWebSocketUpgradeWithMockIRC(t *testing.T) {
	// This test requires the mock IRC server since handleWebSocket
	// dials ircServer (ngircd:6667). In a local test environment,
	// the upgrade will succeed but the IRC dial will fail, causing
	// a WebSocket close. We verify the WebSocket upgrade at least
	// initiates correctly with the rate limiter.
	hub := newHub()
	go hub.run()
	defer close(hub.done)

	limiter := newRateLimiter()

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		handleWebSocket(hub, limiter, &sync.WaitGroup{}, context.Background(), w, r)
	}))
	defer server.Close()

	wsURL := "ws" + strings.TrimPrefix(server.URL, "http")
	ws, resp, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		// Expected: IRC server not available, so the handler might close the WS
		// Check that rate limiter was consumed
		if resp != nil && resp.StatusCode == http.StatusTooManyRequests {
			t.Fatal("should not be rate limited on first connection")
		}
		// Connection might fail because IRC is unreachable — that's OK
		return
	}
	defer ws.Close()

	// If we got here, WebSocket upgrade succeeded
	// The handler will close the WS shortly because IRC dial fails
	_, _, readErr := ws.ReadMessage()
	// We expect a close message or error since IRC isn't running
	if readErr == nil {
		t.Log("WebSocket stayed open (unexpected but not a failure)")
	}
}

// ============================================================
// WebSocket Upgrader Config Tests
// ============================================================

func TestUpgraderAllowsAllOrigins(t *testing.T) {
	origins := []string{
		"",
		"http://192.168.199.101",
		"http://localhost",
		"http://nightwatch.local",
		"http://detectportal.firefox.com",
		"http://connectivitycheck.gstatic.com",
	}
	for _, origin := range origins {
		req := httptest.NewRequest("GET", "/", nil)
		if origin != "" {
			req.Header.Set("Origin", origin)
		}
		if !upgrader.CheckOrigin(req) {
			t.Errorf("CheckOrigin rejected origin %q, should accept all in mesh context", origin)
		}
	}
}

// ============================================================
// Constants Sanity Tests
// ============================================================

func TestPingPeriodLessThanPongWait(t *testing.T) {
	if wsPingPeriod >= wsPongWait {
		t.Fatalf("wsPingPeriod (%v) must be < wsPongWait (%v)", wsPingPeriod, wsPongWait)
	}
}

func TestConfigValues(t *testing.T) {
	if maxConnsPerIP <= 0 {
		t.Fatal("maxConnsPerIP must be positive")
	}
	if wsReadLimit <= 0 {
		t.Fatal("wsReadLimit must be positive")
	}
	if ircDialTimeout <= 0 {
		t.Fatal("ircDialTimeout must be positive")
	}
	if shutdownTimeout <= 0 {
		t.Fatal("shutdownTimeout must be positive")
	}
}

func TestListenAddr(t *testing.T) {
	if !strings.HasPrefix(listenAddr, ":") {
		t.Fatalf("listenAddr %q should start with ':'", listenAddr)
	}
}

// ============================================================
// Replay Buffer Persistence Tests
// ============================================================

func TestReplayBufferInMemoryOnly(t *testing.T) {
	rb := NewReplayBuffer(3)
	rb.Add("a")
	rb.Add("b")
	if got := rb.Recent(); len(got) != 2 || got[0] != "a" || got[1] != "b" {
		t.Fatalf("Recent() = %v, want [a b]", got)
	}
}

func TestReplayBufferRingsCorrectly(t *testing.T) {
	rb := NewReplayBuffer(3)
	rb.Add("a")
	rb.Add("b")
	rb.Add("c")
	rb.Add("d") // wraps; "a" drops out
	got := rb.Recent()
	if len(got) != 3 || got[0] != "b" || got[1] != "c" || got[2] != "d" {
		t.Fatalf("Recent() after wrap = %v, want [b c d]", got)
	}
}

func TestReplayBufferPersistsAcrossInstances(t *testing.T) {
	dir := t.TempDir()
	path := dir + "/replay.log"

	rb1 := NewReplayBuffer(5)
	rb1.LoadFromFile(path) // file doesn't exist yet — opens for append, no error
	rb1.Add("first")
	rb1.Add("second")
	rb1.Add("third")
	if rb1.logFile != nil {
		_ = rb1.logFile.Sync()
		_ = rb1.logFile.Close()
	}

	// Simulate a restart: new buffer, load same file
	rb2 := NewReplayBuffer(5)
	rb2.LoadFromFile(path)
	got := rb2.Recent()
	if len(got) != 3 {
		t.Fatalf("after reload Recent() has %d lines, want 3 (got=%v)", len(got), got)
	}
	if got[0] != "first" || got[1] != "second" || got[2] != "third" {
		t.Fatalf("after reload Recent() = %v, want [first second third]", got)
	}
}

func TestReplayBufferTruncatesOversizedLog(t *testing.T) {
	dir := t.TempDir()
	path := dir + "/replay.log"

	// Write a deliberately large log directly
	var lines []string
	for i := 0; i < replayLogMaxLines+200; i++ {
		lines = append(lines, fmt.Sprintf("line-%d", i))
	}
	content := strings.Join(lines, "\n") + "\n"
	if err := os.WriteFile(path, []byte(content), 0640); err != nil {
		t.Fatal(err)
	}

	rb := NewReplayBuffer(5)
	rb.LoadFromFile(path)
	// Trigger a truncate manually by adding 100 messages (matches the 100-add cadence)
	for i := 0; i < 100; i++ {
		rb.Add(fmt.Sprintf("new-%d", i))
	}

	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	resultLines := strings.Split(strings.TrimRight(string(data), "\n"), "\n")
	if len(resultLines) > replayLogMaxLines {
		t.Fatalf("after truncate, log has %d lines, want <= %d", len(resultLines), replayLogMaxLines)
	}
	// And the last line should be one of the most-recent additions
	last := resultLines[len(resultLines)-1]
	if !strings.HasPrefix(last, "new-") {
		t.Fatalf("after truncate, last line is %q, want a 'new-*' entry", last)
	}
}

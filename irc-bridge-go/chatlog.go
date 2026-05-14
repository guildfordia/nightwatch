package main

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// ChatLogger writes PRIVMSG events to chat-YYYY-MM-DD.jsonl files (one per UTC
// day) when CHAT_LOG_DIR is set. Disabled by default — the contracted CdC
// specifies in-memory replay buffer only (no disk persistence on the Pi).
// Operators who need an archive for documentation/exhibition can opt in by
// setting CHAT_LOG_DIR in the bridge's environment, in which case the
// associated GDPR responsibility (cf. CdC §6.2) is theirs.
//
// Client identity is recorded as SHA256(salt || ip), truncated to 16 hex
// chars. The salt is generated once per deployment and persisted alongside
// the nick counter; reinstalling the bridge rotates it, so cross-deployment
// correlation is impossible.

type ChatLogger struct {
	mu      sync.Mutex
	dir     string
	salt    []byte
	current *os.File
	curDate string
	warned  bool
}

type chatEvent struct {
	Ts         string `json:"ts"`                     // RFC 3339 nanosecond UTC
	Dir        string `json:"dir"`                    // "in" (from fed IRC) or "out" (from local WS)
	Nick       string `json:"nick"`
	Channel    string `json:"channel"`
	Msg        string `json:"msg"`
	ClientHash string `json:"client_hash,omitempty"`  // only set for "out"
}

// chatLogDir returns the archive directory, or empty string if the operator
// has not opted in. Empty disables persistence (default).
func chatLogDir() string {
	return os.Getenv("CHAT_LOG_DIR")
}

func chatSaltPath() string {
	if d := os.Getenv("DATA_DIR"); d != "" {
		return filepath.Join(d, "chat-hash-salt")
	}
	return "/data/chat-hash-salt"
}

func newChatLogger() *ChatLogger {
	dir := chatLogDir()
	if dir == "" {
		// Persistence disabled — return a no-op logger. write() will see an
		// empty dir and short-circuit; we don't load or write the salt.
		return &ChatLogger{}
	}
	return &ChatLogger{dir: dir, salt: loadOrCreateSalt(chatSaltPath())}
}

func loadOrCreateSalt(path string) []byte {
	if data, err := os.ReadFile(path); err == nil && len(data) >= 16 {
		return data
	}
	buf := make([]byte, 32)
	if _, err := rand.Read(buf); err != nil {
		// Fall back to time-seeded value; unique enough for the archive use case.
		return []byte(fmt.Sprintf("nightwatch-salt-%d", time.Now().UnixNano()))
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err == nil {
		_ = os.WriteFile(path, buf, 0o600)
	}
	return buf
}

func (cl *ChatLogger) hashIP(ip string) string {
	if ip == "" {
		return ""
	}
	h := sha256.New()
	h.Write(cl.salt)
	h.Write([]byte(ip))
	sum := h.Sum(nil)
	return hex.EncodeToString(sum)[:16]
}

// LogOutbound is called from readPump for each WS frame the client sent
// toward IRC. rawMsg is the trimmed/truncated payload (e.g. "PRIVMSG #ch :hi").
// Non-PRIVMSG commands (JOIN, NICK, PING…) are silently ignored.
func (cl *ChatLogger) LogOutbound(rawMsg, nick, clientIP string) {
	channel, body, ok := parseOutboundPrivmsg(rawMsg)
	if !ok {
		return
	}
	cl.write(chatEvent{
		Ts:         time.Now().UTC().Format(time.RFC3339Nano),
		Dir:        "out",
		Nick:       nick,
		Channel:    channel,
		Msg:        body,
		ClientHash: cl.hashIP(clientIP),
	})
}

// LogInbound is called from the IRC reader for each PRIVMSG arriving from the
// federation (a message originally sent on another node). rawLine is the full
// IRC line, e.g. ":alice!u@h PRIVMSG #nightwatch :hello".
func (cl *ChatLogger) LogInbound(rawLine string) {
	nick, channel, body, ok := parseInboundPrivmsg(rawLine)
	if !ok {
		return
	}
	cl.write(chatEvent{
		Ts:      time.Now().UTC().Format(time.RFC3339Nano),
		Dir:     "in",
		Nick:    nick,
		Channel: channel,
		Msg:     body,
	})
}

func (cl *ChatLogger) write(ev chatEvent) {
	if cl == nil || cl.dir == "" {
		return
	}
	payload, err := json.Marshal(ev)
	if err != nil {
		return
	}
	payload = append(payload, '\n')

	cl.mu.Lock()
	defer cl.mu.Unlock()

	date := time.Now().UTC().Format("2006-01-02")
	if cl.current == nil || cl.curDate != date {
		if cl.current != nil {
			cl.current.Close()
			cl.current = nil
		}
		if err := os.MkdirAll(cl.dir, 0o755); err != nil {
			if !cl.warned {
				log.Printf("WARNING: chat log dir %s unavailable, archive disabled: %v", cl.dir, err)
				cl.warned = true
			}
			return
		}
		path := filepath.Join(cl.dir, "chat-"+date+".jsonl")
		f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
		if err != nil {
			if !cl.warned {
				log.Printf("WARNING: cannot open chat log %s, archive disabled: %v", path, err)
				cl.warned = true
			}
			return
		}
		cl.current = f
		cl.curDate = date
		cl.warned = false
	}
	if _, err := cl.current.Write(payload); err != nil && !cl.warned {
		log.Printf("WARNING: chat log write failed: %v", err)
		cl.warned = true
	}
}

func (cl *ChatLogger) Close() {
	if cl == nil {
		return
	}
	cl.mu.Lock()
	defer cl.mu.Unlock()
	if cl.current != nil {
		cl.current.Close()
		cl.current = nil
	}
}

// parseOutboundPrivmsg extracts channel + body from an outbound IRC line.
// Returns ok=false for any non-PRIVMSG command so the logger silently
// ignores JOIN, NICK, PART, PING, etc.
func parseOutboundPrivmsg(s string) (channel, body string, ok bool) {
	s = strings.TrimSpace(s)
	if len(s) < len("PRIVMSG #x :y") {
		return "", "", false
	}
	if !strings.EqualFold(s[:8], "PRIVMSG ") {
		return "", "", false
	}
	rest := s[8:]
	sp := strings.IndexByte(rest, ' ')
	if sp <= 0 {
		return "", "", false
	}
	channel = rest[:sp]
	body = strings.TrimPrefix(rest[sp+1:], ":")
	if body == "" {
		return "", "", false
	}
	return channel, body, true
}

// parseInboundPrivmsg extracts sender nick, channel and body from an inbound
// IRC line prefixed with ":nick!user@host PRIVMSG #chan :text".
func parseInboundPrivmsg(s string) (nick, channel, body string, ok bool) {
	s = strings.TrimRight(s, "\r\n")
	if !strings.HasPrefix(s, ":") {
		return "", "", "", false
	}
	sp := strings.IndexByte(s, ' ')
	if sp <= 1 {
		return "", "", "", false
	}
	prefix := s[1:sp]
	rest := s[sp+1:]
	if bang := strings.IndexByte(prefix, '!'); bang >= 0 {
		nick = prefix[:bang]
	} else {
		nick = prefix
	}
	if len(rest) < len("PRIVMSG #x :y") || !strings.EqualFold(rest[:8], "PRIVMSG ") {
		return "", "", "", false
	}
	rest = rest[8:]
	sp = strings.IndexByte(rest, ' ')
	if sp <= 0 {
		return "", "", "", false
	}
	channel = rest[:sp]
	body = strings.TrimPrefix(rest[sp+1:], ":")
	if body == "" {
		return "", "", "", false
	}
	return nick, channel, body, true
}

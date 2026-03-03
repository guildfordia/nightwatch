# IRC bridge — supports pre-built binary or build-from-source.
#
# Fast path (Pi Zero 2 W): run `make build-bridge` on your laptop first.
#   This cross-compiles irc-bridge for linux/arm64.
#   Docker just copies the binary — no Go toolchain needed, builds in seconds.
#
# Slow path (Pi 4/5 or no pre-built binary):
#   Docker builds from source using the Go toolchain (~10min on Zero 2 W).

FROM golang:1.23-bookworm AS builder

ENV CGO_ENABLED=0
# Limit Go compiler memory usage for Pi 3 (1GB RAM)
ENV GOGC=50
ENV GOMEMLIMIT=400MiB

WORKDIR /app

COPY go.mod go.sum ./
COPY main.go ./

# If pre-built binary exists, just verify it. Otherwise, build from source.
COPY irc-bridg* ./
RUN if [ -f irc-bridge ]; then \
      echo "[+] Using pre-built irc-bridge binary (cross-compiled on laptop)"; \
      cp irc-bridge main; \
    else \
      echo "[+] No pre-built binary — building from source..."; \
      go mod download && go build -p 1 -ldflags="-s -w" -o main .; \
    fi

# Use alpine for minimal image size (~5MB vs ~80MB with debian)
FROM alpine:3.21
RUN apk add --no-cache ca-certificates wget
WORKDIR /root/
COPY --from=builder /app/main .
EXPOSE 3000
CMD ["./main"]

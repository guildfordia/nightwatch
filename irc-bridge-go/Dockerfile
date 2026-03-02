FROM golang:1.23-bookworm AS builder

ENV CGO_ENABLED=0
# Limit Go compiler memory usage for Pi 3 (1GB RAM)
ENV GOGC=50
ENV GOMEMLIMIT=400MiB

WORKDIR /app

# Copy dependency files first (cache layer)
COPY go.mod go.sum ./
RUN go mod download

# Copy source and build (single compilation unit, -p 1 = one package at a time)
COPY main.go ./
RUN go build -p 1 -ldflags="-s -w" -o main .

# Use alpine for minimal image size (~5MB vs ~80MB with debian)
FROM alpine:3.21
RUN apk add --no-cache ca-certificates wget
WORKDIR /root/
COPY --from=builder /app/main .
EXPOSE 3000
CMD ["./main"]

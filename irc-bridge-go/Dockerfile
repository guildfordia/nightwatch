FROM golang:1.21-bullseye AS builder

ENV CGO_ENABLED=0

WORKDIR /app

# Copy dependency files first (cache layer)
COPY go.mod go.sum ./
RUN go mod download

# Copy source and build
COPY main.go ./
RUN go build -ldflags="-s -w" -o main .

# Use alpine for minimal image size (~5MB vs ~80MB with debian)
FROM alpine:3.19
RUN apk add --no-cache ca-certificates wget
WORKDIR /root/
COPY --from=builder /app/main .
EXPOSE 3000
CMD ["./main"]

FROM golang:1.21-bullseye AS builder

# Configure Go for direct downloads
ENV GOPROXY=direct
ENV GOSUMDB=off
ENV CGO_ENABLED=0

WORKDIR /app

# Copy source files
COPY go.mod ./
COPY main.go ./

# Download and build
RUN go mod download
RUN go build -o main .

FROM debian:bullseye-slim
RUN apt-get update && apt-get install -y ca-certificates && rm -rf /var/lib/apt/lists/*
WORKDIR /root/
COPY --from=builder /app/main .
EXPOSE 3000
CMD ["./main"] 
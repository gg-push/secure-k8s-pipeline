# Stage 1: Builder
FROM golang:1.26-alpine AS builder

WORKDIR /app

# Download dependencies first (better Docker caching)
COPY go.mod go.sum ./
RUN go mod download

# Copy rest of source code
COPY . .

# Build statically linked binary (no CGO, works on scratch)
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags="-w -s" -o podinfo ./cmd/podinfo

# Stage 2: Production
FROM scratch

WORKDIR /

# Copy compiled binary from builder stage
COPY --from=builder /app/podinfo /podinfo

# Copy UI assets (Podinfo needs this to serve its webpage)
COPY --from=builder /app/ui /ui

# Run as non-root user (Security best practice)
USER 1000:1000

# Expose default port
EXPOSE 9898

ENTRYPOINT ["/podinfo"]

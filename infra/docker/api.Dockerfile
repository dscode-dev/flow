FROM golang:1.27.3-alpine AS build
WORKDIR /src
COPY backend/go.mod backend/go.sum ./
RUN go mod download
COPY backend/ ./
RUN CGO_ENABLED=0 go build -trimpath -o /out/api ./cmd/api && \
    CGO_ENABLED=0 go build -trimpath -o /out/migrate ./cmd/migrate && \
    CGO_ENABLED=0 go build -trimpath -o /out/probe ./cmd/probe

FROM alpine:3.22
RUN apk add --no-cache ca-certificates && addgroup -S flow && adduser -S -G flow flow
WORKDIR /app
COPY --from=build /out/ /app/
COPY backend/migrations/ /app/migrations/
USER flow
EXPOSE 8080
CMD ["/app/api"]

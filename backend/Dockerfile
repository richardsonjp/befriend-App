# syntax=docker/dockerfile:1

FROM golang:1.25-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/apiserver ./cmd/apiserver

FROM alpine:3.22
# tzdata: server loads SYSTEM_TIME_ZONE; ca-certificates: outbound HTTPS (OpenRouter, Apple, Google)
RUN apk add --no-cache ca-certificates tzdata && adduser -D -u 10001 app
WORKDIR /app
COPY --from=build /out/apiserver ./apiserver
# migrations are read from ./cmd/apiserver/app/migrations relative to the working directory
COPY cmd/apiserver/app/migrations ./cmd/apiserver/app/migrations
USER app
EXPOSE 8305
ENTRYPOINT ["./apiserver"]
CMD ["server"]

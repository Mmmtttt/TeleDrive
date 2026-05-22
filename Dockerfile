FROM golang:1.24-alpine AS deps

WORKDIR /src
RUN apk add --no-cache ca-certificates git
COPY go.mod go.sum ./
RUN go mod download
COPY cmd ./cmd

FROM deps AS build-importer
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/teledrive-importer ./cmd/teledrive-importer

FROM deps AS build-bridge
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/teledrive-bridge ./cmd/teledrive-bridge

FROM alpine:3.22 AS runtime
RUN apk add --no-cache ca-certificates && adduser -D -H teledrive
USER teledrive

FROM runtime AS importer
COPY --from=build-importer /out/teledrive-importer /usr/local/bin/teledrive-importer
EXPOSE 8891
ENTRYPOINT ["/usr/local/bin/teledrive-importer"]

FROM runtime AS bridge
COPY --from=build-bridge /out/teledrive-bridge /usr/local/bin/teledrive-bridge
EXPOSE 8892
ENTRYPOINT ["/usr/local/bin/teledrive-bridge"]

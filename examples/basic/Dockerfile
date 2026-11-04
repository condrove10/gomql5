# syntax=docker/dockerfile:1.7
ARG GO_IMAGE=golang:1.24-bookworm
FROM ${GO_IMAGE} AS build
WORKDIR /src
COPY go.mod ./
COPY protocol/ protocol/
COPY mt5/ mt5/
COPY examples/ examples/
RUN CGO_ENABLED=0 go build -trimpath -o /out/basic ./examples/basic

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/basic /basic
EXPOSE 7788
ENTRYPOINT ["/basic"]

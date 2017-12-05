FROM golang:1.9.2

RUN go get github.com/prometheus/prometheus/cmd/promtool
ADD entrypoint.sh entrypoint.sh

CMD [ "./entrypoint.sh" ]

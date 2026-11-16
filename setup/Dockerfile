FROM alpine:3.22
RUN apk add --no-cache openssl
COPY generate.sh /usr/local/bin/generate.sh
RUN chmod +x /usr/local/bin/generate.sh
ENTRYPOINT ["/usr/local/bin/generate.sh"]

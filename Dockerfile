FROM alpine

RUN apk add --no-cache krb5-server krb5 supervisor haveged

COPY supervisord*.conf /etc/

COPY docker-entrypoint.sh /

VOLUME /var/lib/krb5kdc

EXPOSE 749 464 88 80 8001

ENTRYPOINT ["/docker-entrypoint.sh"]

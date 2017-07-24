FROM alpine

RUN apk add --no-cache krb5-server krb5 supervisor haveged

ADD supervisord.conf /etc/supervisord.conf

ADD docker-entrypoint.sh /

VOLUME /var/lib/krb5kdc

EXPOSE 749 464 88 80 8001

ENTRYPOINT ["/docker-entrypoint.sh"]
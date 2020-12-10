# escape=\
#Stage 1 : builder debian image
FROM debian:buster as builder

# properly setup debian sources
ENV DEBIAN_FRONTEND noninteractive
RUN echo "deb http://http.debian.net/debian buster main\n\
deb-src http://http.debian.net/debian buster main\n\
deb http://http.debian.net/debian buster-updates main\n\
deb-src http://http.debian.net/debian buster-updates main\n\
deb http://security.debian.org buster/updates main\n\
deb-src http://security.debian.org buster/updates main\n\
" > /etc/apt/sources.list

# install package building helpers
# rsyslog for logging (ref https://github.com/stilliard/docker-pure-ftpd/issues/17)
RUN apt-get -y update && \
	apt-get -y --force-yes --fix-missing install dpkg-dev debhelper &&\
	apt-get -y build-dep pure-ftpd


# Build from source - we need to remove the need for CAP_SYS_NICE and CAP_DAC_READ_SEARCH
RUN mkdir /tmp/pure-ftpd/ && \
	cd /tmp/pure-ftpd/ && \
	apt-get source pure-ftpd && \
	cd pure-ftpd-* && \
	./configure --with-tls | grep -v '^checking' | grep -v ': Entering directory' | grep -v ': Leaving directory' && \
	sed -i '/CAP_SYS_NICE,/d; /CAP_DAC_READ_SEARCH/d; s/CAP_SYS_CHROOT,/CAP_SYS_CHROOT/;' src/caps_p.h && \
	dpkg-buildpackage -b -uc | grep -v '^checking' | grep -v ': Entering directory' | grep -v ': Leaving directory'


#Stage 2 : actual pure-ftpd image
FROM debian:buster-slim

# feel free to change this ;)
LABEL maintainer "Andrew Stilliard <andrew.stilliard@gmail.com>"

# install dependencies
# FIXME : libcap2 is not a dependency anymore. .deb could be fixed to avoid asking this dependency
ENV DEBIAN_FRONTEND noninteractive
RUN apt-get -y update && \
	apt-get  --no-install-recommends --yes install \
	libc6 \
	libcap2 \
    libmariadb3 \
	libpam0g \
	libssl1.1 \
    lsb-base \
    openbsd-inetd \
    openssl \
    perl \
	rsyslog

COPY --from=builder /tmp/pure-ftpd/*.deb /tmp/pure-ftpd/

# install the new deb files
RUN dpkg -i /tmp/pure-ftpd/pure-ftpd-common*.deb &&\
	dpkg -i /tmp/pure-ftpd/pure-ftpd_*.deb && \
	# dpkg -i /tmp/pure-ftpd/pure-ftpd-ldap_*.deb && \
	# dpkg -i /tmp/pure-ftpd/pure-ftpd-mysql_*.deb && \
	# dpkg -i /tmp/pure-ftpd/pure-ftpd-postgresql_*.deb && \
	rm -Rf /tmp/pure-ftpd

# prevent pure-ftpd upgrading
RUN apt-mark hold pure-ftpd pure-ftpd-common

# setup ftpgroup and ftpuser
RUN groupadd ftpgroup &&\
	useradd -g ftpgroup -d /home/ftpusers -s /dev/null ftpuser

# setup certificate + key in /etc/ssl/private/pure-ftpd.pem
COPY ssl.cnf /tmp/ssl.cnf
RUN mkdir -p /etc/ssl/private &&\
	openssl dhparam -out /etc/ssl/private/pure-ftpd-dhparams.pem 2048 &&\
	openssl req -x509 -nodes -newkey rsa:2048 -sha256 -keyout \
		/etc/ssl/private/pure-ftpd.pem \
		-out /etc/ssl/private/pure-ftpd.pem \
		-config /tmp/ssl.cnf &&\
	chmod 600 /etc/ssl/private/*.pem &&\
	rm /tmp/ssl.cnf


# configure rsyslog logging
RUN echo "" >> /etc/rsyslog.conf && \
	echo "#PureFTP Custom Logging" >> /etc/rsyslog.conf && \
	echo "ftp.* /var/log/pure-ftpd/pureftpd.log" >> /etc/rsyslog.conf && \
	echo "Updated /etc/rsyslog.conf with /var/log/pure-ftpd/pureftpd.log"

# setup run/init file
COPY run.sh /run.sh
RUN chmod u+x /run.sh

# Add users. Piping an echo "pwd\npwd" into pure-pw does not work so we have
# a prebuilt password file which we modify with correct UID
# for I in $(seq 1 10); do echo -e "k$I\nk$I"|./src/pure-pw useradd k$I -u $(whoami) -f pureftpd.passwd  -d /home/ftpusers; done
COPY pureftpd.passwd /etc/pure-ftpd/passwd
RUN for I in $(seq 1 10); do pure-pw usermod k$I -f /etc/pure-ftpd/passwd -u ftpuser -m -d /home/ftpusers; done

# cleaning up
RUN apt-get -y clean \
	&& apt-get -y autoclean \
	&& apt-get -y autoremove \
	&& rm -rf /var/lib/apt/lists/*

# default publichost, you'll need to set this for passive support
ENV PUBLICHOST KServer

# startup, only TLS
CMD /run.sh -l puredb:/etc/pure-ftpd/pureftpd.pdb  -A -c 10 -C 1 -H -Y 2  -E -j -R -P $PUBLICHOST

EXPOSE 21 30000-30009

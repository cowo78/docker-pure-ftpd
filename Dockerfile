# escape=\
# The resulting image can be run with
# docker run -d --rm -p 21:21 -p 30000-30009:30000-30009 -h kserver <image>
# Hostname must be set to kserver (used by pureftpd too) or passive mode will
# not work.

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
    useradd -g ftpgroup -d /home/ftpusers -s /dev/null ftpuser &&\
    mkdir /home/ftpusers &&\
    chown -R ftpuser.ftpgroup /home/ftpusers

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

# Create home directories
RUN for I in $(seq 1 10); do mkdir /home/ftpusers/k$I; done
RUN chown -R ftpuser.ftpgroup /home/ftpusers

# Add users 'k1' ... 'k10' with password same as user
# home = /home/ftpusers/<username>
RUN for I in $(seq 1 10); do (echo k$I; echo k$I) | pure-pw useradd k$I -f /etc/pure-ftpd/pureftpd.passwd -u ftpuser -d /home/ftpusers/k$I -m; done
# Add 'kroot:kroot' user with home = /home/ftpusers
RUN (echo kroot; echo kroot) | pure-pw useradd kroot -f /etc/pure-ftpd/pureftpd.passwd -u ftpuser -d /home/ftpusers -m

# cleaning up
RUN apt-get -y clean \
	&& apt-get -y autoclean \
	&& apt-get -y autoremove \
	&& rm -rf /var/lib/apt/lists/*

# Setup for PASV support
ENV PUBLICHOST KServer
ENV FTP_MAX_CLIENTS 10
ENV FTP_MAX_CONNECTIONS 1
ENV FTP_PASSIVE_PORTS 30000:30009
# -A = chroot
# -H = don't log hostnames, only IPs
# -d = add debugging log
# -E = no anonymous users
ENV ADDED_FLAGS -A -H

# startup, TLS enabled by run.sh
CMD /run.sh -l puredb:/etc/pure-ftpd/pureftpd.pdb -j -R -P $PUBLICHOST

EXPOSE 21 30000-30009

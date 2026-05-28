FROM ubuntu:22.04
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    git build-essential cmake pkg-config python3 python3-pip ca-certificates \
    libssl-dev libc-ares-dev libwebsockets-dev libwrap0-dev libcjson-dev libsqlite3-dev libargon2-dev libreadline-dev libmicrohttpd-dev libxslt1-dev libxml2-utils xsltproc docbook-xsl wget curl && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /src
RUN git clone https://github.com/eclipse/mosquitto.git mosquitto
WORKDIR /src/mosquitto
RUN git submodule update --init --recursive || true

RUN mkdir -p build && cd build && \
    CFLAGS="-g -O1 -fsanitize=address -fno-omit-frame-pointer" \
    CXXFLAGS="-g -O1 -fsanitize=address -fno-omit-frame-pointer" \
    LDFLAGS="-fsanitize=address" \
    cmake -DCMAKE_BUILD_TYPE=Debug -DWITH_MAN=OFF -DWITH_TESTS=OFF .. && \
    make -j$(nproc) && make install

# install a small helper (socat) for tests if available
RUN apt-get update && apt-get install -y --no-install-recommends socat && rm -rf /var/lib/apt/lists/*

CMD ["/usr/local/sbin/mosquitto", "-v"]

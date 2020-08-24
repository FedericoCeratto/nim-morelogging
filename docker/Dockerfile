FROM nimlang/nim:1.2.6-ubuntu

RUN apt-get update -yqq \
    && apt-get install -y --no-install-recommends \
               libsystemd-dev \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY . /app

# install dependencies
RUN nimble install -Y

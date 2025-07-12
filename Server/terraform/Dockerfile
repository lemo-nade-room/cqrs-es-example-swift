# syntax=docker/dockerfile:1
FROM public.ecr.aws/ubuntu/ubuntu:noble AS runtime

COPY --from=public.ecr.aws/awsguru/aws-lambda-adapter:0.9.1 /lambda-adapter /opt/extensions/lambda-adapter

RUN export DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true \
    && apt-get -q update \
    && apt-get -q dist-upgrade -y \
    && apt-get -q install -y \
      libjemalloc2 \
      ca-certificates \
      tzdata \
      libssl3 \
      libcurl4 \
      libxml2 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY ./App /app/
RUN chmod +x /app/App
ENV AWS_LWA_PORT=3001

ENTRYPOINT ["./App"]
CMD ["serve", "--env", "production", "--hostname", "0.0.0.0", "--port", "3001"]

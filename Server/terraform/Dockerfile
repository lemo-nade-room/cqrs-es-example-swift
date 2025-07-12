# syntax=docker/dockerfile:1
# ================================
# Build image
# ================================
FROM public.ecr.aws/docker/library/swift:6.1-noble AS build

# Install OS updates and dependencies
# これらのレイヤーは変更頻度が低いため最初に配置
RUN export DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true \
    && apt-get -q update \
    && apt-get -q dist-upgrade -y \
    && apt-get install -y \
    libjemalloc-dev \
    libssl-dev \
    openssl \
    pkg-config \
    && rm -rf /var/lib/apt/lists/*

# Set up a build area
WORKDIR /build

# First just resolve dependencies.
# Package.swift と Package.resolved だけをコピーして依存関係を解決
# これにより、これらのファイルが変更されない限りキャッシュが有効
COPY ./Server/Package.* ./
RUN --mount=type=cache,id=swiftpm-cache,target=/root/.swiftpm \
    --mount=type=cache,id=swift-build,target=/build/.build \
    swift package resolve \
            $([ -f ./Package.resolved ] && echo "--force-resolved-versions" || true)

# Copy source code
# ソースコードの変更頻度が高いため、最後にコピー
COPY ./Server/Sources ./Sources
COPY ./Server/Tests ./Tests

# Build the application with optimizations
# BuildKitのキャッシュマウントを使用して、ビルドキャッシュを永続化
RUN --mount=type=cache,id=swiftpm-cache,target=/root/.swiftpm \
    --mount=type=cache,id=swift-build,target=/build/.build \
    swift build -c release \
            --product CommandServer \
            --static-swift-stdlib \
            -Xlinker -ljemalloc

# Copy built executable to a known location
# キャッシュマウントを使用してビルド結果を取得
RUN --mount=type=cache,id=swiftpm-cache,target=/root/.swiftpm \
    --mount=type=cache,id=swift-build,target=/build/.build \
    BIN_PATH=$(swift build --package-path /build -c release --show-bin-path) && \
    cp "$BIN_PATH/CommandServer" /build/CommandServer && \
    cp "/usr/libexec/swift/linux/swift-backtrace-static" /build/swift-backtrace-static && \
    # Copy resources if they exist
    [ -d /build/Public ] && cp -r /build/Public /build/Public-copy || true && \
    [ -d /build/Resources ] && cp -r /build/Resources /build/Resources-copy || true

# ================================
# Runtime image
# ================================
FROM public.ecr.aws/ubuntu/ubuntu:noble AS runtime

# Lambda Web Adapter
# 最新バージョンを使用（0.9.1）
COPY --from=public.ecr.aws/awsguru/aws-lambda-adapter:0.9.1 /lambda-adapter /opt/extensions/lambda-adapter

# Install runtime dependencies only
# ランタイムに必要な最小限のパッケージのみインストール
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

# Create app directory
WORKDIR /app

# Copy only the necessary files from builder
COPY --from=build /build/CommandServer /app/
COPY --from=build /build/swift-backtrace-static /app/

# Set permissions and copy resources if exists
RUN mkdir -p /app/Public /app/Resources

# Set permissions
RUN chmod +x /app/CommandServer && \
    chmod +x /app/swift-backtrace-static

# Provide configuration for crash reporter
ENV SWIFT_BACKTRACE=enable=yes,sanitize=yes,threads=all,images=all,interactive=no,swift-backtrace=./swift-backtrace-static

# Lambda Web Adapter Settings
# ポート3001を使用（1024以上、9001と3000以外）
ENV AWS_LWA_PORT=3001

# Start the Vapor service
ENTRYPOINT ["./CommandServer"]
CMD ["serve", "--env", "production", "--hostname", "0.0.0.0", "--port", "3001"]

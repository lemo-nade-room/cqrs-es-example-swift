# syntax=docker/dockerfile:1
# ================================
# Build image
# ================================
FROM public.ecr.aws/docker/library/swift:6.1-noble AS build

# Install OS updates
RUN export DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true \
    && apt-get -q update \
    && apt-get -q dist-upgrade -y \
    && apt-get install -y \
    libjemalloc-dev \
    libssl-dev \
    openssl \
    pkg-config

# Set up a build area
WORKDIR /build

# First just resolve dependencies.
# This creates a cached layer that can be reused
# as long as your Package.swift/Package.resolved
# files do not change.
COPY Package.* ./
RUN swift package resolve \
        $([ -f ./Package.resolved ] && echo "--force-resolved-versions" || true)

# Copy only source code to avoid cache invalidation from other changes
COPY Sources ./Sources
# Copy test directories to satisfy Package.swift dependencies
COPY Tests ./Tests

# Build the application and copy to staging in one step
# This ensures the binary is available after the cache mount is unmounted
WORKDIR /staging
RUN cd /build && \
    swift build -c release \
        --product CommandServer \
        --static-swift-stdlib \
        -Xlinker -ljemalloc \
        -Xswiftc -j8 \
        -Xswiftc -enable-batch-mode && \
    cp "$(swift build --package-path /build -c release --show-bin-path)/CommandServer" /staging/ || \
    find /build/.build -name CommandServer -type f -executable -exec cp {} /staging/ \;

# Copy static swift backtracer binary to staging area
RUN cp "/usr/libexec/swift/linux/swift-backtrace-static" ./

# Copy resources bundled by SPM to staging area
# Note: Resources need to be copied while the build directory is still accessible
RUN find -L /build/.build -regex '.*\.resources$' -exec cp -Ra {} ./ \; || true

# Copy any resources from the build context if they exist
# Note: These are copied from the build context, not from the build stage
RUN [ -d /build/Public ] && cp -R /build/Public ./ || true
RUN [ -d /build/Resources ] && cp -R /build/Resources ./ || true

# Ensure resources are not writable
RUN [ -d ./Public ] && chmod -R a-w ./Public || true
RUN [ -d ./Resources ] && chmod -R a-w ./Resources || true

# ================================
# Run image
# ================================
FROM public.ecr.aws/ubuntu/ubuntu:noble

# Lambda Web Adapter - copy with exact filename
COPY --from=public.ecr.aws/awsguru/aws-lambda-adapter:0.9.1 /lambda-adapter /opt/extensions/lambda-adapter

# Make sure all system packages are up to date, and install only essential packages.
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
    && rm -r /var/lib/apt/lists/*

# Switch to the new home directory
WORKDIR /app

# Copy built executable and any staged resources from builder
COPY --from=build /staging /app

# Provide configuration needed by the built-in crash reporter and some sensible default behaviors.
ENV SWIFT_BACKTRACE=enable=yes,sanitize=yes,threads=all,images=all,interactive=no,swift-backtrace=./swift-backtrace-static

# Lambda Web Adapter Settings
ENV PORT=3001
ENV AWS_LWA_PORT=3001

# Let Docker bind to port 3001
EXPOSE 3001

# Start the Vapor service when the image is run, default to listening on 3001 in production environment
ENTRYPOINT ["/app/CommandServer"]
CMD ["serve", "--env", "production", "--hostname", "0.0.0.0", "--port", "3001"]

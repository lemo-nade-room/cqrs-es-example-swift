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

# Build the application and copy to staging
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
FROM --platform=linux/arm64 public.ecr.aws/lambda/provided:al2-arm64

# Lambda Web Adapter - copy to extensions directory with proper ownership
COPY --chown=root:root --from=public.ecr.aws/awsguru/aws-lambda-adapter:0.9.1 /lambda-adapter /opt/extensions/lambda-adapter
RUN chmod +x /opt/extensions/lambda-adapter

# Install runtime dependencies
RUN yum update -y && \
    yum install -y \
      jemalloc \
      openssl \
      libcurl \
      libxml2 \
    && yum clean all

# Set working directory
WORKDIR /var/task

# Copy built executable and any staged resources from builder
COPY --from=build /staging /var/task

# Provide configuration needed by the built-in crash reporter and some sensible default behaviors.
ENV SWIFT_BACKTRACE=enable=yes,sanitize=yes,threads=all,images=all,interactive=no,swift-backtrace=./swift-backtrace-static

# Lambda Web Adapter will auto-configure port

# Let Docker bind to port 3001
EXPOSE 3001

# Ensure the binary is executable
RUN chmod +x /var/task/CommandServer

# Lambda Web Adapter will start our app
# Clear the default ENTRYPOINT from provided:al2 image
ENTRYPOINT []
CMD ["/var/task/CommandServer", "serve", "--env", "production", "--hostname", "0.0.0.0", "--port", "3001"]

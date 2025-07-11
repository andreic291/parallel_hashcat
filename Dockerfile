FROM ubuntu:22.04

# Avoid interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Update and install dependencies
RUN apt-get update && apt-get install -y \
    hashcat \
    opencl-headers \
    ocl-icd-opencl-dev \
    wget \
    curl \
    time \
    bc \
    && rm -rf /var/lib/apt/lists/*

# Create working directory
WORKDIR /hashcat-test

# Copy test files
COPY test.hc22000 /hashcat-test/
COPY massive_wordlist.txt /hashcat-test/

# Create directory for results
RUN mkdir -p /hashcat-test/results

# Set default command
CMD ["/bin/bash"] 
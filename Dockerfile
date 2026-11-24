FROM public.ecr.aws/amazonlinux/amazonlinux:2023-minimal

# Install curl and AWS CLI v2 in a single layer
# curl-minimal is pre-installed in amazonlinux:2023-minimal — no need to install curl
RUN dnf install -y --nodocs \
      unzip \
      ca-certificates \
    && curl -sSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip \
    && unzip -q /tmp/awscliv2.zip -d /tmp \
    && /tmp/aws/install \
    && rm -rf /tmp/awscliv2.zip /tmp/aws \
    && dnf clean all

# Allow OpenShift to write the assigned UID into /etc/passwd at runtime
RUN chmod g=u /etc/passwd

COPY download-report.sh /usr/local/bin/download-report.sh
RUN chmod +x /usr/local/bin/download-report.sh

# Run as non-root — OpenShift assigns the actual UID from the namespace range
USER 65534

ENTRYPOINT ["/usr/local/bin/download-report.sh"]

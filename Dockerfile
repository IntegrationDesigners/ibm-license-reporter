FROM public.ecr.aws/amazonlinux/amazonlinux:2023-minimal

# Install curl and AWS CLI v2 in a single layer
# curl-minimal is pre-installed in amazonlinux:2023-minimal — no need to install curl
# shadow-utils provides useradd (not included in the minimal image)
RUN dnf install -y --nodocs \
      unzip \
      ca-certificates \
      shadow-utils \
    && curl -sSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip \
    && unzip -q /tmp/awscliv2.zip -d /tmp \
    && /tmp/aws/install \
    && rm -rf /tmp/awscliv2.zip /tmp/aws \
    && dnf clean all

# Non-root user for OpenShift restricted SCC
RUN useradd -u 1001 -r -g 0 -s /sbin/nologin reporter \
    && chmod g=u /etc/passwd

COPY download-report.sh /usr/local/bin/download-report.sh
RUN chmod +x /usr/local/bin/download-report.sh

USER 1001

ENTRYPOINT ["/usr/local/bin/download-report.sh"]

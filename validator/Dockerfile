FROM python:3.11-slim

# Install iptables for Phase 2 (not used in Phase 1 stub)
RUN apt-get update && \
    apt-get install -y --no-install-recommends iptables && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN mkdir -p /data

COPY validator.py .

EXPOSE 8088

CMD ["python3", "validator.py"]

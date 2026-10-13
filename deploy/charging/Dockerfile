FROM python:3.12-slim
WORKDIR /app
COPY tools/charging/collector.py tools/charging/check_feeds.py tools/charging/feeds.toml tools/charging/collection.toml ./
USER 1000:1000
CMD ["python", "collector.py", "--database", "/data/charging.sqlite"]

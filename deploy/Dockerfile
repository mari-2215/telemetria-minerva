FROM python:3.12-slim AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /opt/minerva
COPY pyproject.toml README.md ./
COPY shared ./shared
COPY backend ./backend
COPY edge ./edge
RUN pip install --no-cache-dir .

RUN useradd --system --uid 10001 minerva && mkdir -p /var/lib/minerva && chown minerva:minerva /var/lib/minerva
USER minerva

ENV MINERVA_DB_PATH=/var/lib/minerva/backend.db
EXPOSE 8080
CMD ["minerva-api"]


FROM python:3.12-slim
WORKDIR /api
COPY app/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app/ .
# Run as an unprivileged user instead of root. A numeric ID, so Kubernetes can
# verify runAsNonRoot without looking up the name.
RUN useradd --uid 10001 --no-create-home --shell /usr/sbin/nologin appuser
USER 10001
EXPOSE 8000 9000
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]

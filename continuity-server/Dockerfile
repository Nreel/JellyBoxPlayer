FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY main.py store.py ./

EXPOSE 8000

# Same probe compose uses, so plain `docker run` reports health too.
HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=5s \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health')"

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]

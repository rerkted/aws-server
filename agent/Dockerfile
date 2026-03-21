FROM python:3.12-slim

WORKDIR /app

# Patch OS packages
RUN apt-get update && apt-get upgrade -y && apt-get clean && rm -rf /var/lib/apt/lists/*

# Install Python deps
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy app and static files
COPY app/ ./app/
COPY static/ ./static/

EXPOSE 3003

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "3003", "--workers", "1"]

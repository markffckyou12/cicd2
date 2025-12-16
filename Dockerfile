FROM python:3.9-slim
COPY app.py .
CMD ["python", "app.py"]

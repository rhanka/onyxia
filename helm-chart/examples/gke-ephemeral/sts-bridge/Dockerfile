FROM python:3.12-slim AS build
WORKDIR /app
COPY pyproject.toml .
RUN pip install --prefix=/install --no-cache-dir .
COPY app/ ./app/

FROM gcr.io/distroless/python3-debian12:nonroot
COPY --from=build /install /usr/local
COPY --from=build /app/app /app/app
WORKDIR /app
USER nonroot
EXPOSE 8080
ENTRYPOINT ["python", "-m", "uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8080"]

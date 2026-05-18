FROM python:3.12-slim AS build
WORKDIR /src
COPY pyproject.toml .
COPY app/ ./app/
RUN pip install --prefix=/install --no-cache-dir .

FROM python:3.12-slim
ENV PYTHONUNBUFFERED=1
COPY --from=build /install /usr/local
COPY --from=build /src/app /app/app
WORKDIR /app
RUN useradd --create-home --uid 65532 appuser
USER 65532
EXPOSE 8080
ENTRYPOINT ["python", "-m", "uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8080"]

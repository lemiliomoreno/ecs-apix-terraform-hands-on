FROM python:3.11

ENV PYTHONBUFFERED 1

WORKDIR /app

COPY . .

RUN pip install --upgrade pip
RUN pip install -r requirements.txt

EXPOSE 80

ENTRYPOINT ["/bin/bash", "docker-entrypoint.sh"]

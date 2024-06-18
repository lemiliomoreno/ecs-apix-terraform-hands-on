#!/bin/bash

# Apply database migrations
python manage.py migrate

# Run API
gunicorn --bind 0.0.0.0:80 app.wsgi

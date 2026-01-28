import os
from datetime import timedelta
from pathlib import Path

from dotenv import load_dotenv

BASE_DIR = Path(__file__).resolve().parent.parent
load_dotenv(BASE_DIR / ".env")

SECRET_KEY = os.environ.get("DJANGO_SECRET_KEY", "dev-chave-insegura")
DEBUG = os.environ.get("DJANGO_DEBUG", "1") == "1"
ALLOWED_HOSTS = [
    host
    for host in os.environ.get(
        "DJANGO_ALLOWED_HOSTS",
        "localhost,127.0.0.1" if DEBUG else "",
    ).split(",")
    if host.strip()
]
CSRF_TRUSTED_ORIGINS = [
    origin
    for origin in os.environ.get("DJANGO_CSRF_TRUSTED_ORIGINS", "").split(",")
    if origin.strip()
]

INSTALLED_APPS = [
    "django.contrib.admin",
    "django.contrib.auth",
    "django.contrib.contenttypes",
    "django.contrib.sessions",
    "django.contrib.messages",
    "django.contrib.staticfiles",
    "channels",
    "rest_framework",
    "rest_framework_simplejwt.token_blacklist",
    "corsheaders",
    "corridas",
    "geo",
]

MIDDLEWARE = [
    "corsheaders.middleware.CorsMiddleware",
    "django.middleware.security.SecurityMiddleware",
    "whitenoise.middleware.WhiteNoiseMiddleware",
    "django.contrib.sessions.middleware.SessionMiddleware",
    "django.middleware.common.CommonMiddleware",
    "django.middleware.csrf.CsrfViewMiddleware",
    "django.contrib.auth.middleware.AuthenticationMiddleware",
    "django.contrib.messages.middleware.MessageMiddleware",
    "django.middleware.clickjacking.XFrameOptionsMiddleware",
]

ROOT_URLCONF = "vai_paqueta.urls"

TEMPLATES = [
    {
        "BACKEND": "django.template.backends.django.DjangoTemplates",
        "DIRS": [BASE_DIR / "templates"],
        "APP_DIRS": True,
        "OPTIONS": {
            "context_processors": [
                "django.template.context_processors.debug",
                "django.template.context_processors.request",
                "django.contrib.auth.context_processors.auth",
                "django.contrib.messages.context_processors.messages",
            ],
        },
    },
]

WSGI_APPLICATION = "vai_paqueta.wsgi.application"
ASGI_APPLICATION = "vai_paqueta.asgi.application"

REDIS_URL = os.environ.get("REDIS_URL", "redis://127.0.0.1:6379/0")
USE_REDIS = os.environ.get("DJANGO_USE_REDIS", "0" if DEBUG else "1").lower() in ("1", "true", "yes")
if USE_REDIS:
    CHANNEL_LAYERS = {
        "default": {
            "BACKEND": "channels_redis.core.RedisChannelLayer",
            "CONFIG": {"hosts": [REDIS_URL]},
        }
    }
else:
    CHANNEL_LAYERS = {
        "default": {"BACKEND": "channels.layers.InMemoryChannelLayer"},
    }

DB_PATH = os.environ.get("DJANGO_DB_PATH")
DATABASES = {
    "default": {
        "ENGINE": "django.db.backends.sqlite3",
        "NAME": DB_PATH or (BASE_DIR / "db.sqlite3"),
    }
}

AUTH_PASSWORD_VALIDATORS = []

LANGUAGE_CODE = "pt-br"
TIME_ZONE = "America/Sao_Paulo"
USE_I18N = True
USE_TZ = True

STATIC_URL = "/static/"
STATIC_ROOT = BASE_DIR / "staticfiles"
STATICFILES_DIRS = [BASE_DIR / "static"]

DEFAULT_AUTO_FIELD = "django.db.models.BigAutoField"

CORS_ALLOW_ALL_ORIGINS = os.environ.get(
    "DJANGO_CORS_ALLOW_ALL",
    "1" if DEBUG else "0",
).lower() in ("1", "true", "yes")
CORS_ALLOWED_ORIGINS = [
    origin
    for origin in os.environ.get("DJANGO_CORS_ALLOWED_ORIGINS", "").split(",")
    if origin.strip()
]

REST_FRAMEWORK = {
    "DEFAULT_AUTHENTICATION_CLASSES": [
        "vai_paqueta.authentication.CookieJWTAuthentication",
    ],
    "DEFAULT_PERMISSION_CLASSES": [
        "rest_framework.permissions.IsAuthenticated",
    ],
}

SIMPLE_JWT = {
    "ACCESS_TOKEN_LIFETIME": timedelta(minutes=15),
    "REFRESH_TOKEN_LIFETIME": timedelta(days=7),
    "ROTATE_REFRESH_TOKENS": True,
    "BLACKLIST_AFTER_ROTATION": True,
}

JWT_COOKIE_SECURE = os.environ.get(
    "DJANGO_JWT_COOKIE_SECURE",
    "0" if DEBUG else "1",
).lower() in ("1", "true", "yes")
JWT_COOKIE_SAMESITE = os.environ.get("DJANGO_JWT_COOKIE_SAMESITE", "Strict")
JWT_COOKIE_DOMAIN = os.environ.get("DJANGO_JWT_COOKIE_DOMAIN", "") or None
JWT_COOKIE_PATH = os.environ.get("DJANGO_JWT_COOKIE_PATH", "/")

CORS_ALLOW_CREDENTIALS = os.environ.get("DJANGO_CORS_ALLOW_CREDENTIALS", "0").lower() in (
    "1",
    "true",
    "yes",
)

# Caminhos para os dados de vias desenhadas manualmente.
ROADS_JSON_PATH = os.environ.get("ROADS_JSON_PATH", str(BASE_DIR / "geo" / "roads.json"))
ROADS_GEOJSON_PATH = os.environ.get("ROADS_GEOJSON_PATH", str(BASE_DIR / "geo" / "roads.geojson"))
ROADS_SNAP_DECIMALS = int(os.environ.get("ROADS_SNAP_DECIMALS", "5"))
ROADS_CONNECT_RADIUS = float(os.environ.get("ROADS_CONNECT_RADIUS", "12.0"))
ROADS_TRACE_DISTANCE = float(os.environ.get("ROADS_TRACE_DISTANCE", "25.0"))
# Distância máxima entre vértices antes de gerar pontos extras na malha manual.
ROADS_DENSIFY_MAX_SEGMENT_M = float(os.environ.get("ROADS_DENSIFY_MAX_SEGMENT_M", "15.0"))

# Caminho para o catálogo offline de endereços (usado no backend de geocodificação).
ADDRESSES_JSON_PATH = os.environ.get(
    "ADDRESSES_JSON_PATH",
    str(BASE_DIR / "static" / "landing" / "data" / "addresses.json"),
)
ADDRESSES_REVERSE_MAX_DISTANCE_M = float(os.environ.get("ADDRESSES_REVERSE_MAX_DISTANCE_M", "250.0"))

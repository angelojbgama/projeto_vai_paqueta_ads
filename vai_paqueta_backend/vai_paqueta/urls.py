from django.conf import settings
from django.conf.urls.static import static
from django.contrib import admin
from django.urls import include, path

from .auth_views import LoginView, MeView, RegisterView
from .views import landing, webapp

urlpatterns = [
    path("admin/", admin.site.urls),
    path("api/auth/register/", RegisterView.as_view(), name="auth_register"),
    path("api/auth/login/", LoginView.as_view(), name="auth_login"),
    path("api/auth/me/", MeView.as_view(), name="auth_me"),
    path("api/", include("corridas.urls")),
    path("api/geo/", include("geo.urls")),
    path("", landing, name="landing"),
    path("app/", webapp, name="webapp"),
]

if settings.DEBUG:
    urlpatterns += static(settings.STATIC_URL, document_root=settings.STATIC_ROOT)

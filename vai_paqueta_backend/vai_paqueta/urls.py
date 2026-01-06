from django.conf import settings
from django.conf.urls.static import static
from django.contrib import admin
from django.urls import include, path
from .auth_views import CookieTokenRefreshView, LoginView, LogoutView, MeView, RegisterView
from .views import landing, privacy, tutorial, webapp

urlpatterns = [
    path("admin/", admin.site.urls),
    path("api/auth/register/", RegisterView.as_view(), name="auth_register"),
    path("api/auth/login/", LoginView.as_view(), name="auth_login"),
    path("api/auth/me/", MeView.as_view(), name="auth_me"),
    path("api/auth/logout/", LogoutView.as_view(), name="auth_logout"),
    path("api/auth/token/refresh/", CookieTokenRefreshView.as_view(), name="token_refresh"),
    path("api/", include("corridas.urls")),
    path("api/geo/", include("geo.urls")),
    path("", landing, name="landing"),
    path("app/", webapp, name="webapp"),
    path("privacidade/", privacy, name="privacy"),
    path("tutorial/", tutorial, name="tutorial"),
]

if settings.DEBUG:
    urlpatterns += static(settings.STATIC_URL, document_root=settings.STATIC_ROOT)

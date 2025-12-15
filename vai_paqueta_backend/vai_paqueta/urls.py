from django.contrib import admin
from django.urls import include, path

urlpatterns = [
    path("admin/", admin.site.urls),
    path("api/", include("corridas.urls")),
    path("api/geo/", include("geo.urls")),
]


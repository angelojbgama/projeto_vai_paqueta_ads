from django.urls import include, path
from rest_framework.routers import DefaultRouter

from .views import CorridaViewSet, DeviceRegisterView, LocalizacaoPingViewSet, MotoristasProximosView

router = DefaultRouter()
router.register(r"corridas", CorridaViewSet, basename="corridas")
router.register(r"pings", LocalizacaoPingViewSet, basename="pings")

urlpatterns = [
    path("device/registrar/", DeviceRegisterView.as_view(), name="registrar_device"),
    path("motoristas-proximos/", MotoristasProximosView.as_view(), name="motoristas_proximos"),
    path("", include(router.urls)),
]



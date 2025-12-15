from django.urls import path

from .views import ForwardGeocodeView, NearbySearchView, ReverseGeocodeView

urlpatterns = [
    path("reverse/", ReverseGeocodeView.as_view(), name="reverse_geocode"),
    path("forward/", ForwardGeocodeView.as_view(), name="forward_geocode"),
    path("search/", NearbySearchView.as_view(), name="nearby_search"),
]

from django.urls import path

from .views import (
    CountryListView,
    ForwardGeocodeView,
    NearbySearchView,
    ReverseGeocodeView,
    RoadsGeoJSONView,
    RoadsView,
    RouteView,
    AddressesView,
)

urlpatterns = [
    path("reverse/", ReverseGeocodeView.as_view(), name="reverse_geocode"),
    path("forward/", ForwardGeocodeView.as_view(), name="forward_geocode"),
    path("search/", NearbySearchView.as_view(), name="nearby_search"),
    path("addresses/", AddressesView.as_view(), name="addresses"),
    path("countries/", CountryListView.as_view(), name="country_list"),
    path("roads/", RoadsView.as_view(), name="roads"),
    path("roads/geojson/", RoadsGeoJSONView.as_view(), name="roads_geojson"),
    path("route/", RouteView.as_view(), name="route"),
]

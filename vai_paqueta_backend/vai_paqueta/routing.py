from django.urls import path

from corridas import consumers

websocket_urlpatterns = [
    path("ws/driver/", consumers.DriverConsumer.as_asgi()),
    path("ws/passenger/", consumers.PassengerConsumer.as_asgi()),
]

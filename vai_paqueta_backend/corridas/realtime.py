from __future__ import annotations

from typing import Iterable, Optional

from asgiref.sync import async_to_sync
from channels.layers import get_channel_layer
from django.utils import timezone

from .models import Corrida
from .serializers import CorridaSerializer

ACTIVE_STATUSES = ["aguardando", "aceita", "em_andamento"]


def group_driver(perfil_id: int) -> str:
    return f"driver_{perfil_id}"


def group_passenger(perfil_id: int) -> str:
    return f"passenger_{perfil_id}"


def group_ride(corrida_id: int) -> str:
    return f"ride_{corrida_id}"


def _broadcast(groups: Iterable[str], payload: dict) -> None:
    channel_layer = get_channel_layer()
    if not channel_layer:
        return
    for group in groups:
        async_to_sync(channel_layer.group_send)(group, {"type": "corrida.event", "event": payload})


def notify_corrida(corrida: Corrida, event_type: str = "ride_update") -> None:
    data = CorridaSerializer(corrida).data
    payload = {"type": event_type, "corrida": data}
    groups = [group_ride(corrida.id)]
    if corrida.cliente_id:
        groups.append(group_passenger(corrida.cliente_id))
    if corrida.motorista_id:
        groups.append(group_driver(corrida.motorista_id))
    _broadcast(groups, payload)


def notify_driver_location(
    *,
    perfil_id: int,
    latitude: float,
    longitude: float,
    precisao_m: Optional[float] = None,
    bearing: Optional[float] = None,
    ping_em=None,
    corrida_id: Optional[int] = None,
) -> None:
    corrida = None
    if corrida_id:
        corrida = Corrida.objects.filter(id=corrida_id, status__in=ACTIVE_STATUSES).first()
    if not corrida:
        corrida = (
            Corrida.objects.filter(motorista_id=perfil_id, status__in=ACTIVE_STATUSES)
            .order_by("-atualizado_em", "-criado_em")
            .first()
        )
    if not corrida or not corrida.cliente_id:
        return
    payload = {
        "type": "driver_location",
        "corrida_id": corrida.id,
        "latitude": latitude,
        "longitude": longitude,
        "precisao_m": precisao_m,
        "bearing": bearing, # Include bearing
        "ping_em": (ping_em or timezone.now()).isoformat(),
    }
    groups = [group_ride(corrida.id), group_passenger(corrida.cliente_id)]
    _broadcast(groups, payload)

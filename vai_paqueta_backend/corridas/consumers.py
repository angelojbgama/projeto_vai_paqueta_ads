from __future__ import annotations

from typing import Optional

from channels.db import database_sync_to_async
from channels.generic.websocket import AsyncJsonWebsocketConsumer

from .models import Corrida, LocalizacaoPing, Perfil
from .realtime import ACTIVE_STATUSES, group_driver, group_passenger, group_ride, notify_driver_location
from .serializers import CorridaSerializer
from .views import _auto_atribuir_por_ping


class BaseRideConsumer(AsyncJsonWebsocketConsumer):
    perfil: Optional[Perfil] = None
    perfil_id: int = 0
    perfil_tipo: str = ""
    base_group: Optional[str] = None

    async def connect(self):
        user = self.scope.get("user")
        if not user or not user.is_authenticated:
            await self.close(code=4401)
            return
        perfil = await self._get_perfil(user.id)
        if not perfil:
            await self.close(code=4404)
            return
        if not self._perfil_autorizado(perfil):
            await self.close(code=4403)
            return
        self.perfil = perfil
        self.perfil_id = perfil.id
        self.perfil_tipo = perfil.tipo
        self.base_group = self._base_group_name(perfil)
        await self.accept()
        if self.base_group:
            await self.channel_layer.group_add(self.base_group, self.channel_name)
        await self.send_json(
            {
                "type": "connected",
                "perfil_id": self.perfil_id,
                "perfil_tipo": self.perfil_tipo,
            }
        )

    async def disconnect(self, close_code):
        if self.base_group:
            await self.channel_layer.group_discard(self.base_group, self.channel_name)

    async def receive_json(self, content, **kwargs):
        msg_type = (content.get("type") or "").lower()
        if msg_type == "subscribe_ride":
            ride_id = content.get("ride_id")
            if isinstance(ride_id, int) and await self._pode_assinar_corrida(ride_id):
                await self.channel_layer.group_add(group_ride(ride_id), self.channel_name)
                await self.send_json({"type": "subscribed", "ride_id": ride_id})
            return
        if msg_type == "unsubscribe_ride":
            ride_id = content.get("ride_id")
            if isinstance(ride_id, int):
                await self.channel_layer.group_discard(group_ride(ride_id), self.channel_name)
                await self.send_json({"type": "unsubscribed", "ride_id": ride_id})
            return
        if msg_type == "sync":
            data = await self._get_corrida_ativa()
            await self.send_json({"type": "ride_update", "corrida": data})
            return

    async def corrida_event(self, event):
        payload = event.get("event")
        if payload:
            await self.send_json(payload)

    def _perfil_autorizado(self, perfil: Perfil) -> bool:  # pragma: no cover - override
        return False

    def _base_group_name(self, perfil: Perfil) -> Optional[str]:  # pragma: no cover - override
        return None

    @database_sync_to_async
    def _get_perfil(self, user_id: int) -> Optional[Perfil]:
        return Perfil.objects.filter(user_id=user_id).first()

    @database_sync_to_async
    def _pode_assinar_corrida(self, corrida_id: int) -> bool:
        if not self.perfil_id:
            return False
        if self.perfil_tipo == "ecotaxista":
            return Corrida.objects.filter(
                id=corrida_id,
                status__in=ACTIVE_STATUSES,
                motorista_id=self.perfil_id,
            ).exists()
        return Corrida.objects.filter(
            id=corrida_id,
            status__in=ACTIVE_STATUSES,
            cliente_id=self.perfil_id,
        ).exists()

    @database_sync_to_async
    def _get_corrida_ativa(self):
        if not self.perfil_id:
            return None
        if self.perfil_tipo == "ecotaxista":
            corrida = (
                Corrida.objects.filter(motorista_id=self.perfil_id, status__in=ACTIVE_STATUSES)
                .order_by("-atualizado_em", "-criado_em")
                .first()
            )
        else:
            corrida = (
                Corrida.objects.filter(cliente_id=self.perfil_id, status__in=ACTIVE_STATUSES)
                .order_by("-atualizado_em", "-criado_em")
                .first()
            )
        return CorridaSerializer(corrida).data if corrida else None


class DriverConsumer(BaseRideConsumer):
    def _perfil_autorizado(self, perfil: Perfil) -> bool:
        return perfil.tipo == "ecotaxista"

    def _base_group_name(self, perfil: Perfil) -> Optional[str]:
        return group_driver(perfil.id)

    async def receive_json(self, content, **kwargs):
        msg_type = (content.get("type") or "").lower()
        if msg_type == "ping":
            if not self.perfil_id:
                return
            lat = content.get("latitude")
            lng = content.get("longitude")
            if lat is None or lng is None:
                return
            await self._registrar_ping(lat, lng, content.get("precisao_m"), content.get("corrida_id"))
            await self.send_json({"type": "pong"})
            return
        await super().receive_json(content, **kwargs)

    @database_sync_to_async
    def _registrar_ping(self, lat, lng, precisao_m=None, corrida_id=None):
        if not self.perfil_id:
            return
        ping = LocalizacaoPing.objects.create(
            perfil_id=self.perfil_id,
            latitude=lat,
            longitude=lng,
            precisao_m=precisao_m,
        )
        try:
            perfil = Perfil.objects.filter(id=self.perfil_id).first()
            if perfil:
                _auto_atribuir_por_ping(perfil, float(ping.latitude), float(ping.longitude))
        except Exception:
            pass
        notify_driver_location(
            perfil_id=self.perfil_id,
            latitude=float(ping.latitude),
            longitude=float(ping.longitude),
            precisao_m=ping.precisao_m,
            ping_em=ping.criado_em,
            corrida_id=corrida_id if isinstance(corrida_id, int) else None,
        )


class PassengerConsumer(BaseRideConsumer):
    def _perfil_autorizado(self, perfil: Perfil) -> bool:
        return perfil.tipo in ("passageiro", "cliente")

    def _base_group_name(self, perfil: Perfil) -> Optional[str]:
        return group_passenger(perfil.id)

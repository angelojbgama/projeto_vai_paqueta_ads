import math
import uuid
from datetime import datetime, timedelta, timezone

from django.db.models import Q
from rest_framework import status, viewsets
from rest_framework.decorators import action
from rest_framework.response import Response
from rest_framework.views import APIView

from .models import Corrida, Device, LocalizacaoPing, Perfil
from .serializers import (
    CorridaCreateSerializer,
    CorridaSerializer,
    CorridaStatusSerializer,
    DeviceSerializer,
    LocalizacaoPingSerializer,
    PerfilSerializer,
)


def _haversine_km(lat1, lon1, lat2, lon2):
    # Distância aproximada em km entre dois pontos lat/lng
    r = 6371
    phi1, phi2 = math.radians(lat1), math.radians(lat2)
    dphi = math.radians(lat2 - lat1)
    dlambda = math.radians(lon2 - lon1)
    a = math.sin(dphi / 2) ** 2 + math.cos(phi1) * math.cos(phi2) * math.sin(dlambda / 2) ** 2
    return 2 * r * math.atan2(math.sqrt(a), math.sqrt(1 - a))


class DeviceRegisterView(APIView):
    """
    Registra ou recupera um device e garante um perfil padrão.
    """

    def post(self, request):
        payload_uuid = request.data.get("device_uuid")
        plataforma = request.data.get("plataforma", "")
        tipo = request.data.get("tipo", "passageiro")
        nome = request.data.get("nome", "")

        device = None
        if payload_uuid:
            try:
                payload_uuid = uuid.UUID(str(payload_uuid))
                device, created = Device.objects.get_or_create(
                    device_uuid=payload_uuid, defaults={"plataforma": plataforma}
                )
                if not created and plataforma:
                    device.plataforma = plataforma
                    device.save(update_fields=["plataforma"])
            except (ValueError, Device.DoesNotExist):
                device = None

        if device is None:
            device = Device.objects.create(plataforma=plataforma)

        perfil, _created = Perfil.objects.get_or_create(device=device, tipo=tipo, defaults={"nome": nome})
        serializer = DeviceSerializer(device)
        return Response(
            {"device": serializer.data, "perfil": PerfilSerializer(perfil).data},
            status=status.HTTP_201_CREATED,
        )


class CorridaViewSet(viewsets.ModelViewSet):
    queryset = Corrida.objects.select_related("cliente__device", "motorista__device").all()
    serializer_class = CorridaSerializer
    http_method_names = ["get", "post", "patch"]

    def get_queryset(self):
        qs = super().get_queryset()
        perfil_id = self.request.query_params.get("perfil_id")
        device_uuid = self.request.query_params.get("device_uuid")
        if perfil_id:
            qs = qs.filter(Q(cliente_id=perfil_id) | Q(motorista_id=perfil_id))
        if device_uuid:
            qs = qs.filter(
                Q(cliente__device__device_uuid=device_uuid) | Q(motorista__device__device_uuid=device_uuid)
            )
        return qs.order_by("-criado_em")

    def create(self, request, *args, **kwargs):
        # Bloqueia criação direta; use a ação solicitar
        return Response({"detail": "Use POST /api/corridas/solicitar."}, status=status.HTTP_405_METHOD_NOT_ALLOWED)

    @action(detail=False, methods=["post"], url_path="solicitar")
    def solicitar(self, request):
        serializer = CorridaCreateSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        data = serializer.validated_data
        try:
            perfil = Perfil.objects.get(id=data["perfil_id"], tipo__in=["cliente", "passageiro"])
        except Perfil.DoesNotExist:
            return Response({"detail": "Perfil de passageiro/cliente não encontrado."}, status=status.HTTP_404_NOT_FOUND)

        corrida = Corrida.objects.create(
            cliente=perfil,
            origem_lat=data["origem_lat"],
            origem_lng=data["origem_lng"],
            destino_lat=data["destino_lat"],
            destino_lng=data["destino_lng"],
            origem_endereco=data.get("origem_endereco", ""),
            destino_endereco=data.get("destino_endereco", ""),
        )
        return Response(CorridaSerializer(corrida).data, status=status.HTTP_201_CREATED)

    @action(detail=True, methods=["post"], url_path="aceitar")
    def aceitar(self, request, pk=None):
        corrida = self.get_object()
        serializer = CorridaStatusSerializer(data={**request.data, "status": "aceita"})
        serializer.is_valid(raise_exception=True)
        motorista_id = serializer.validated_data.get("motorista_id")
        if not motorista_id:
            return Response({"detail": "motorista_id é obrigatório."}, status=status.HTTP_400_BAD_REQUEST)
        try:
            motorista = Perfil.objects.get(id=motorista_id, tipo="ecotaxista")
        except Perfil.DoesNotExist:
            return Response({"detail": "Motorista não encontrado."}, status=status.HTTP_404_NOT_FOUND)
        corrida.status = "aceita"
        corrida.motorista = motorista
        corrida.save(update_fields=["status", "motorista", "atualizado_em"])
        return Response(CorridaSerializer(corrida).data)

    @action(detail=True, methods=["post"], url_path="iniciar")
    def iniciar(self, request, pk=None):
        corrida = self.get_object()
        motorista_id = request.data.get("motorista_id")
        if not motorista_id:
            return Response({"detail": "motorista_id é obrigatório."}, status=status.HTTP_400_BAD_REQUEST)
        if not corrida.motorista or corrida.motorista_id != int(motorista_id):
            return Response({"detail": "Corrida não atribuída a este motorista."}, status=status.HTTP_403_FORBIDDEN)
        if corrida.status not in ["aceita", "aguardando"]:
            return Response({"detail": f"Corrida não pode ser iniciada no status {corrida.status}."}, status=400)
        corrida.status = "em_andamento"
        corrida.save(update_fields=["status", "atualizado_em"])
        return Response(CorridaSerializer(corrida).data)

    @action(detail=True, methods=["post"], url_path="finalizar")
    def finalizar(self, request, pk=None):
        corrida = self.get_object()
        motorista_id = request.data.get("motorista_id")
        if not motorista_id:
            return Response({"detail": "motorista_id é obrigatório."}, status=status.HTTP_400_BAD_REQUEST)
        if not corrida.motorista or corrida.motorista_id != int(motorista_id):
            return Response({"detail": "Corrida não atribuída a este motorista."}, status=status.HTTP_403_FORBIDDEN)
        if corrida.status not in ["em_andamento", "aceita"]:
            return Response({"detail": f"Corrida não pode ser finalizada no status {corrida.status}."}, status=400)
        corrida.status = "concluida"
        corrida.save(update_fields=["status", "atualizado_em"])
        return Response(CorridaSerializer(corrida).data)

    @action(detail=True, methods=["post"], url_path="cancelar")
    def cancelar(self, request, pk=None):
        corrida = self.get_object()
        corrida.status = "cancelada"
        corrida.save(update_fields=["status", "atualizado_em"])
        return Response(CorridaSerializer(corrida).data)

    @action(detail=True, methods=["post"], url_path="status")
    def atualizar_status(self, request, pk=None):
        corrida = self.get_object()
        serializer = CorridaStatusSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        novo_status = serializer.validated_data["status"]
        motorista_id = serializer.validated_data.get("motorista_id")
        if motorista_id:
            try:
                motorista = Perfil.objects.get(id=motorista_id, tipo="ecotaxista")
                corrida.motorista = motorista
            except Perfil.DoesNotExist:
                return Response({"detail": "Motorista não encontrado."}, status=status.HTTP_404_NOT_FOUND)
        corrida.status = novo_status
        corrida.save(update_fields=["status", "motorista", "atualizado_em"])
        return Response(CorridaSerializer(corrida).data)

    @action(
        detail=False,
        methods=["get"],
        url_path=r"para_motorista/(?P<motorista_id>[^/.]+)",
    )
    def para_motorista(self, request, motorista_id=None):
        """
        Retorna a corrida mais recente atribuída a este motorista e ainda não finalizada/cancelada.
        Estados considerados: aguardando, aceita, em_andamento.
        """
        try:
            motorista_id_int = int(motorista_id)
        except (TypeError, ValueError):
            return Response({"detail": "motorista_id inválido."}, status=status.HTTP_400_BAD_REQUEST)

        corrida = (
            Corrida.objects.filter(
                motorista_id=motorista_id_int,
                status__in=["aguardando", "aceita", "em_andamento"],
            )
            .order_by("-atualizado_em", "-criado_em")
            .first()
        )
        if not corrida:
            return Response({}, status=status.HTTP_200_OK)
        return Response(CorridaSerializer(corrida).data)


class LocalizacaoPingViewSet(viewsets.ModelViewSet):
    queryset = LocalizacaoPing.objects.select_related("perfil__device").all()
    serializer_class = LocalizacaoPingSerializer
    http_method_names = ["get", "post"]

    def get_queryset(self):
        qs = super().get_queryset()
        perfil_id = self.request.query_params.get("perfil_id")
        device_uuid = self.request.query_params.get("device_uuid")
        if perfil_id:
            qs = qs.filter(perfil_id=perfil_id)
        if device_uuid:
            qs = qs.filter(perfil__device__device_uuid=device_uuid)
        return qs.order_by("-criado_em")


class MotoristasProximosView(APIView):
    def get(self, request):
        try:
            lat = float(request.query_params.get("lat"))
            lng = float(request.query_params.get("lng"))
        except (TypeError, ValueError):
            return Response({"detail": "lat e lng são obrigatórios."}, status=status.HTTP_400_BAD_REQUEST)

        raio_km = float(request.query_params.get("raio_km", 3))
        minutos = int(request.query_params.get("minutos", 10))
        limite = int(request.query_params.get("limite", 20))

        limite_tempo = datetime.now(timezone.utc) - timedelta(minutes=minutos)
        pings = (
            LocalizacaoPing.objects.select_related("perfil__device")
            .filter(perfil__tipo="ecotaxista", criado_em__gte=limite_tempo)
            .order_by("-criado_em")
        )

        resposta = []
        for ping in pings:
            dist = _haversine_km(lat, lng, float(ping.latitude), float(ping.longitude))
            if dist <= raio_km:
                resposta.append(
                    {
                        "perfil_id": ping.perfil_id,
                        "device_uuid": str(ping.perfil.device.device_uuid),
                        "latitude": float(ping.latitude),
                        "longitude": float(ping.longitude),
                        "precisao_m": ping.precisao_m,
                        "dist_km": round(dist, 3),
                        "ping_em": ping.criado_em,
                    }
                )
            if len(resposta) >= limite:
                break

        return Response(resposta)

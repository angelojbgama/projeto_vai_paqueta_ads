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

ACTIVE_STATUSES = ["aguardando", "aceita", "em_andamento"]
PING_MAX_AGE_MINUTES = 5


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

        if tipo == "cliente":
            tipo = "passageiro"
        tipos_validos = {choice[0] for choice in Perfil.TIPO_CHOICES}
        if tipo not in tipos_validos:
            return Response({"detail": "tipo inválido. Use 'passageiro' ou 'ecotaxista'."}, status=status.HTTP_400_BAD_REQUEST)

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

    def _corrida_expirada(self, corrida: Corrida) -> bool:
        """
        Considera expirada apenas se aguardando por mais de 2 minutos.
        """
        if corrida.status != "aguardando":
            return False
        referencia = corrida.criado_em
        if not referencia:
            return False
        agora = datetime.now(timezone.utc)
        if agora - referencia > timedelta(minutes=2):
            corrida.status = "rejeitada"
            corrida.motorista = None
            corrida.save(update_fields=["status", "motorista", "atualizado_em"])
            self._atribuir_motorista_proximo(corrida)
            return True
        return False

    def _atribuir_motorista_proximo(self, corrida: Corrida, excluir_motorista_id: int | None = None):
        """
        Seleciona automaticamente um ecotaxista próximo baseado em pings recentes.
        """
        if corrida.origem_lat is None or corrida.origem_lng is None:
            return None
        limite_tempo = datetime.now(timezone.utc) - timedelta(minutes=PING_MAX_AGE_MINUTES)
        pings = (
            LocalizacaoPing.objects.select_related("perfil__device")
            .filter(perfil__tipo="ecotaxista", criado_em__gte=limite_tempo)
            .order_by("-criado_em")
        )
        vistos = set()
        candidatos = []
        for ping in pings:
            if ping.perfil_id in vistos:
                continue
            if excluir_motorista_id and ping.perfil_id == excluir_motorista_id:
                continue
            dist = _haversine_km(
                float(corrida.origem_lat),
                float(corrida.origem_lng),
                float(ping.latitude),
                float(ping.longitude),
            )
            vistos.add(ping.perfil_id)
            candidatos.append((dist, ping.perfil))
        candidatos.sort(key=lambda x: x[0])
        if not candidatos:
            return None
        novo_motorista = candidatos[0][1]
        corrida.motorista = novo_motorista
        corrida.status = "aguardando"
        corrida.save(update_fields=["motorista", "status", "atualizado_em"])
        return novo_motorista

    @action(detail=False, methods=["post"], url_path="solicitar")
    def solicitar(self, request):
        serializer = CorridaCreateSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        data = serializer.validated_data
        try:
            perfil = Perfil.objects.get(id=data["perfil_id"], tipo__in=["cliente", "passageiro"])
        except Perfil.DoesNotExist:
            return Response({"detail": "Perfil de passageiro/cliente não encontrado."}, status=status.HTTP_404_NOT_FOUND)

        corrida_existente = (
            Corrida.objects.filter(cliente=perfil, status__in=ACTIVE_STATUSES)
            .order_by("-atualizado_em", "-criado_em")
            .first()
        )
        if corrida_existente:
            return Response(
                {"detail": "Já existe uma corrida ativa para este perfil.", "corrida": CorridaSerializer(corrida_existente).data},
                status=status.HTTP_409_CONFLICT,
            )

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
        if self._corrida_expirada(corrida):
            return Response({"detail": "Corrida expirada para aceitação."}, status=status.HTTP_409_CONFLICT)
        serializer = CorridaStatusSerializer(data={**request.data, "status": "aceita"})
        serializer.is_valid(raise_exception=True)
        motorista_id = serializer.validated_data.get("motorista_id")
        if not motorista_id:
            return Response({"detail": "motorista_id é obrigatório."}, status=status.HTTP_400_BAD_REQUEST)
        try:
            motorista = Perfil.objects.get(id=motorista_id, tipo="ecotaxista")
        except Perfil.DoesNotExist:
            return Response({"detail": "Motorista não encontrado."}, status=status.HTTP_404_NOT_FOUND)
        if corrida.status != "aguardando":
            return Response({"detail": f"Corrida não pode ser aceita no status {corrida.status}."}, status=status.HTTP_409_CONFLICT)
        if corrida.motorista and corrida.motorista_id != motorista.id:
            return Response({"detail": "Corrida já atribuída a outro motorista."}, status=status.HTTP_409_CONFLICT)
        corrida.status = "aceita"
        corrida.motorista = motorista
        corrida.save(update_fields=["status", "motorista", "atualizado_em"])
        return Response(CorridaSerializer(corrida).data)

    @action(detail=True, methods=["post"], url_path="iniciar")
    def iniciar(self, request, pk=None):
        corrida = self.get_object()
        if self._corrida_expirada(corrida):
            return Response({"detail": "Corrida expirada."}, status=status.HTTP_409_CONFLICT)
        motorista_id = request.data.get("motorista_id")
        if not motorista_id:
            return Response({"detail": "motorista_id é obrigatório."}, status=status.HTTP_400_BAD_REQUEST)
        try:
            motorista = Perfil.objects.get(id=motorista_id, tipo="ecotaxista")
        except Perfil.DoesNotExist:
            return Response({"detail": "Motorista não encontrado."}, status=status.HTTP_404_NOT_FOUND)
        if not corrida.motorista or corrida.motorista_id != motorista.id:
            return Response({"detail": "Corrida não atribuída a este motorista."}, status=status.HTTP_403_FORBIDDEN)
        if corrida.status != "aceita":
            return Response({"detail": f"Corrida não pode ser iniciada no status {corrida.status}."}, status=status.HTTP_409_CONFLICT)
        corrida.status = "em_andamento"
        corrida.save(update_fields=["status", "atualizado_em"])
        return Response(CorridaSerializer(corrida).data)

    @action(detail=True, methods=["post"], url_path="finalizar")
    def finalizar(self, request, pk=None):
        corrida = self.get_object()
        if self._corrida_expirada(corrida):
            return Response({"detail": "Corrida expirada."}, status=status.HTTP_409_CONFLICT)
        motorista_id = request.data.get("motorista_id")
        if not motorista_id:
            return Response({"detail": "motorista_id é obrigatório."}, status=status.HTTP_400_BAD_REQUEST)
        try:
            motorista = Perfil.objects.get(id=motorista_id, tipo="ecotaxista")
        except Perfil.DoesNotExist:
            return Response({"detail": "Motorista não encontrado."}, status=status.HTTP_404_NOT_FOUND)
        if not corrida.motorista or corrida.motorista_id != motorista.id:
            return Response({"detail": "Corrida não atribuída a este motorista."}, status=status.HTTP_403_FORBIDDEN)
        if corrida.status != "em_andamento":
            return Response({"detail": f"Corrida não pode ser finalizada no status {corrida.status}."}, status=status.HTTP_409_CONFLICT)
        corrida.status = "concluida"
        corrida.save(update_fields=["status", "atualizado_em"])
        return Response(CorridaSerializer(corrida).data)

    @action(detail=True, methods=["post"], url_path="cancelar")
    def cancelar(self, request, pk=None):
        corrida = self.get_object()
        perfil_id = request.data.get("perfil_id")
        if perfil_id:
            try:
                Perfil.objects.get(id=perfil_id)
            except Perfil.DoesNotExist:
                return Response({"detail": "Perfil não encontrado para cancelar."}, status=status.HTTP_404_NOT_FOUND)
        corrida.status = "cancelada"
        corrida.save(update_fields=["status", "atualizado_em"])
        return Response(CorridaSerializer(corrida).data)

    @action(detail=True, methods=["post"], url_path="reatribuir")
    def reatribuir(self, request, pk=None):
        """
        Libera a corrida para reatribuição após timeout ou rejeição.
        """
        corrida = self.get_object()
        if corrida.status not in ["aguardando", "aceita", "rejeitada"]:
            return Response({"detail": "Corrida não pode ser reatribuída nesse status."}, status=400)
        excluir_id = request.data.get("excluir_motorista_id")
        corrida.motorista = None
        corrida.status = "aguardando"
        corrida.save(update_fields=["motorista", "status", "atualizado_em"])
        self._atribuir_motorista_proximo(corrida, excluir_motorista_id=excluir_id if excluir_id else None)
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
                status__in=ACTIVE_STATUSES,
            )
            .order_by("-atualizado_em", "-criado_em")
            .first()
        )
        if not corrida:
            return Response({}, status=status.HTTP_200_OK)
        if self._corrida_expirada(corrida):
            return Response({}, status=status.HTTP_200_OK)
        # ignora corridas cujo motorista não pingou recentemente
        ultimo_ping = (
            LocalizacaoPing.objects.filter(perfil_id=motorista_id_int)
            .order_by("-criado_em")
            .values("criado_em")
            .first()
        )
        if not ultimo_ping or ultimo_ping["criado_em"] < datetime.now(timezone.utc) - timedelta(minutes=PING_MAX_AGE_MINUTES):
            return Response({}, status=status.HTTP_200_OK)
        return Response(CorridaSerializer(corrida).data)

    @action(
        detail=False,
        methods=["get"],
        url_path=r"para_passageiro/(?P<passageiro_id>[^/.]+)",
    )
    def para_passageiro(self, request, passageiro_id=None):
        """
        Retorna a corrida mais recente deste passageiro em estados ativos.
        """
        try:
            passageiro_id_int = int(passageiro_id)
        except (TypeError, ValueError):
            return Response({"detail": "passageiro_id inválido."}, status=status.HTTP_400_BAD_REQUEST)

        corrida = (
            Corrida.objects.filter(
                cliente_id=passageiro_id_int,
                status__in=ACTIVE_STATUSES,
            )
            .order_by("-atualizado_em", "-criado_em")
            .first()
        )
        if not corrida:
            return Response({}, status=status.HTTP_200_OK)
        if self._corrida_expirada(corrida):
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

        vistos: dict[int, tuple[float, LocalizacaoPing]] = {}
        for ping in pings:
            if ping.perfil_id in vistos:
                continue
            dist = _haversine_km(lat, lng, float(ping.latitude), float(ping.longitude))
            if dist <= raio_km:
                vistos[ping.perfil_id] = (dist, ping)

        resposta = []
        for dist, ping in sorted(vistos.values(), key=lambda item: item[0])[:limite]:
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

        return Response(resposta)

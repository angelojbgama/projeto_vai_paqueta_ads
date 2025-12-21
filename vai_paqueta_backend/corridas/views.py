import math
import uuid
from datetime import datetime, timedelta, timezone

from django.db import transaction
from django.db.models import Q
from django.shortcuts import get_object_or_404
from rest_framework import status, viewsets
from rest_framework.decorators import action
from rest_framework.exceptions import PermissionDenied
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView

from .models import Corrida, LocalizacaoPing, Perfil
from .serializers import (
    CorridaCreateSerializer,
    CorridaSerializer,
    CorridaStatusSerializer,
    LocalizacaoPingSerializer,
    PerfilSerializer,
)

ACTIVE_STATUSES = ["aguardando", "aceita", "em_andamento"]
PING_MAX_AGE_MINUTES = 5
DISTANCIA_MAX_INICIO_KM = 0.25  # motorista precisa estar próximo da origem para iniciar
TEMPO_CANCELAMENTO_APOS_INICIO = timedelta(minutes=1)
MAX_MOTORISTAS_TENTADOS = 50


def _haversine_km(lat1, lon1, lat2, lon2):
    # Distância aproximada em km entre dois pontos lat/lng
    r = 6371
    phi1, phi2 = math.radians(lat1), math.radians(lat2)
    dphi = math.radians(lat2 - lat1)
    dlambda = math.radians(lon2 - lon1)
    a = math.sin(dphi / 2) ** 2 + math.cos(phi1) * math.cos(phi2) * math.sin(dlambda / 2) ** 2
    return 2 * r * math.atan2(math.sqrt(a), math.sqrt(1 - a))


def _limitar_motoristas_tentados(lista):
    if not lista:
        return []
    unique = list(dict.fromkeys(int(x) for x in lista if x is not None))
    if len(unique) > MAX_MOTORISTAS_TENTADOS:
        unique = unique[-MAX_MOTORISTAS_TENTADOS:]
    return unique


class DeviceRegisterView(APIView):
    """
    Atualiza o modo do usuário (passageiro/ecotaxista) e associa dados do device ao próprio usuário.
    Requer autenticação.
    """

    permission_classes = [IsAuthenticated]

    def post(self, request):
        user = request.user
        if not user or not user.is_authenticated:
            return Response({"detail": "Autenticação obrigatória."}, status=status.HTTP_401_UNAUTHORIZED)

        payload_uuid = request.data.get("device_uuid")
        plataforma = request.data.get("plataforma", "")
        tipo = request.data.get("tipo", "passageiro")
        nome = (request.data.get("nome") or "").strip() or user.first_name

        if tipo == "cliente":
            tipo = "passageiro"
        tipos_validos = {choice[0] for choice in Perfil.TIPO_CHOICES}
        if tipo not in tipos_validos:
            return Response({"detail": "tipo inválido. Use 'passageiro' ou 'ecotaxista'."}, status=status.HTTP_400_BAD_REQUEST)

        perfil, _created = Perfil.objects.get_or_create(
            user=user, defaults={"tipo": tipo, "plataforma": plataforma, "nome": nome}
        )
        if payload_uuid:
            try:
                perfil.device_uuid = uuid.UUID(str(payload_uuid))
            except ValueError:
                return Response({"detail": "device_uuid inválido."}, status=status.HTTP_400_BAD_REQUEST)
        perfil.tipo = tipo
        if plataforma:
            perfil.plataforma = plataforma
        if nome:
            perfil.nome = nome
        perfil.save()

        return Response(
            {
                "device": {"device_uuid": str(perfil.device_uuid), "plataforma": perfil.plataforma},
                "perfil": PerfilSerializer(perfil).data,
            },
            status=status.HTTP_200_OK,
        )


class CorridaViewSet(viewsets.ModelViewSet):
    queryset = Corrida.objects.select_related("cliente__user", "motorista__user").all()
    serializer_class = CorridaSerializer
    http_method_names = ["get", "post", "patch"]
    permission_classes = [IsAuthenticated]

    def get_queryset(self):
        qs = super().get_queryset()
        perfil_id = self.request.query_params.get("perfil_id")
        if perfil_id:
            qs = qs.filter(Q(cliente_id=perfil_id) | Q(motorista_id=perfil_id))
        return qs.order_by("-criado_em")

    def create(self, request, *args, **kwargs):
        # Bloqueia criação direta; use a ação solicitar
        return Response({"detail": "Use POST /api/corridas/solicitar."}, status=status.HTTP_405_METHOD_NOT_ALLOWED)

    def _corrida_expirada(self, corrida: Corrida) -> bool:
        """
        Considera expirada apenas se aguardando com motorista atribuído por mais de 2 minutos.
        """
        if corrida.status != "aguardando":
            return False
        if not corrida.motorista_id:
            return False
        referencia = corrida.atualizado_em or corrida.criado_em
        if not referencia:
            return False
        agora = datetime.now(timezone.utc)
        if agora - referencia > timedelta(minutes=2):
            motorista_expirado_id = corrida.motorista_id
            corrida.motoristas_tentados = _limitar_motoristas_tentados(
                (corrida.motoristas_tentados or []) + [motorista_expirado_id]
            )
            corrida.status = "aguardando"
            corrida.motorista = None
            corrida.save(update_fields=["status", "motorista", "atualizado_em", "motoristas_tentados"])
            self._atribuir_motorista_proximo(
                corrida,
                excluir_motorista_id=motorista_expirado_id,
                allow_reset=False,
            )
            return True
        return False

    def _atribuir_motorista_proximo(
        self, corrida: Corrida, excluir_motorista_id: int | None = None, allow_reset: bool = True
    ):
        """
        Seleciona automaticamente um ecotaxista próximo baseado em pings recentes.
        """
        if corrida.origem_lat is None or corrida.origem_lng is None:
            return None
        limite_tempo = datetime.now(timezone.utc) - timedelta(minutes=PING_MAX_AGE_MINUTES)
        pings = (
            LocalizacaoPing.objects.select_related("perfil__user")
            .filter(perfil__tipo="ecotaxista", criado_em__gte=limite_tempo)
            .order_by("-criado_em")
        )
        vistos = set()
        candidatos = []
        excluidos = set(corrida.motoristas_tentados or [])
        total_pingados = 0
        for ping in pings:
            if ping.perfil_id in vistos:
                continue
            if excluir_motorista_id and ping.perfil_id == excluir_motorista_id:
                continue
            total_pingados += 1
            if ping.perfil_id in excluidos:
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
        if not candidatos and allow_reset and excluidos and total_pingados:
            # Tentou todos os pingados; limpa tentados e tenta novamente
            corrida.motoristas_tentados = []
            corrida.save(update_fields=["motoristas_tentados", "atualizado_em"])
            return self._atribuir_motorista_proximo(corrida, excluir_motorista_id=excluir_motorista_id, allow_reset=False)
        if not candidatos:
            return None
        novo_motorista = candidatos[0][1]
        corrida.motorista = novo_motorista
        corrida.status = "aguardando"
        tentativa_lista = set(corrida.motoristas_tentados or [])
        tentativa_lista.add(novo_motorista.id)
        corrida.motoristas_tentados = _limitar_motoristas_tentados(list(tentativa_lista))
        corrida.save(update_fields=["motorista", "status", "atualizado_em", "motoristas_tentados"])
        return novo_motorista

    def _dist_motorista_origem_km(self, corrida: Corrida) -> float | None:
        """
        Retorna a distância em km entre o último ping do motorista e a origem da corrida.
        """
        if not corrida.motorista_id or corrida.origem_lat is None or corrida.origem_lng is None:
            return None
        ping = (
            LocalizacaoPing.objects.filter(perfil_id=corrida.motorista_id)
            .order_by("-criado_em")
            .values("latitude", "longitude")
            .first()
        )
        if not ping:
            return None
        return _haversine_km(
            float(corrida.origem_lat),
            float(corrida.origem_lng),
            float(ping["latitude"]),
            float(ping["longitude"]),
        )

    @action(detail=False, methods=["post"], url_path="solicitar")
    def solicitar(self, request):
        serializer = CorridaCreateSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        data = serializer.validated_data
        try:
            perfil = Perfil.objects.get(id=data["perfil_id"], tipo__in=["cliente", "passageiro"])
        except Perfil.DoesNotExist:
            return Response({"detail": "Perfil de passageiro/cliente não encontrado."}, status=status.HTTP_404_NOT_FOUND)
        if perfil.user_id and request.user and request.user.is_authenticated and perfil.user_id != request.user.id:
            raise PermissionDenied("Perfil não pertence ao usuário autenticado.")

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
        self._atribuir_motorista_proximo(corrida)
        return Response(CorridaSerializer(corrida).data, status=status.HTTP_201_CREATED)

    @action(detail=True, methods=["post"], url_path="aceitar")
    def aceitar(self, request, pk=None):
        with transaction.atomic():
            corrida = get_object_or_404(self.get_queryset().select_for_update(), pk=pk)
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
            if motorista.user_id and request.user and request.user.is_authenticated and motorista.user_id != request.user.id:
                raise PermissionDenied("Perfil não pertence ao usuário autenticado.")
            if corrida.status != "aguardando":
                return Response(
                    {"detail": f"Corrida não pode ser aceita no status {corrida.status}."},
                    status=status.HTTP_409_CONFLICT,
                )
            if corrida.motorista and corrida.motorista_id != motorista.id:
                return Response({"detail": "Corrida já atribuída a outro motorista."}, status=status.HTTP_409_CONFLICT)
            corrida.status = "aceita"
            corrida.motorista = motorista
            corrida.save(update_fields=["status", "motorista", "atualizado_em"])
            return Response(CorridaSerializer(corrida).data)

    @action(detail=True, methods=["post"], url_path="iniciar")
    def iniciar(self, request, pk=None):
        with transaction.atomic():
            corrida = get_object_or_404(self.get_queryset().select_for_update(), pk=pk)
            if self._corrida_expirada(corrida):
                return Response({"detail": "Corrida expirada."}, status=status.HTTP_409_CONFLICT)
            motorista_id = request.data.get("motorista_id")
            if not motorista_id:
                return Response({"detail": "motorista_id é obrigatório."}, status=status.HTTP_400_BAD_REQUEST)
            try:
                motorista = Perfil.objects.get(id=motorista_id, tipo="ecotaxista")
            except Perfil.DoesNotExist:
                return Response({"detail": "Motorista não encontrado."}, status=status.HTTP_404_NOT_FOUND)
            if motorista.user_id and request.user and request.user.is_authenticated and motorista.user_id != request.user.id:
                raise PermissionDenied("Perfil não pertence ao usuário autenticado.")
            if not corrida.motorista or corrida.motorista_id != motorista.id:
                return Response({"detail": "Corrida não atribuída a este motorista."}, status=status.HTTP_403_FORBIDDEN)
            if corrida.status != "aceita":
                return Response(
                    {"detail": f"Corrida não pode ser iniciada no status {corrida.status}."},
                    status=status.HTTP_409_CONFLICT,
                )
            dist_km = self._dist_motorista_origem_km(corrida)
            if dist_km is None:
                return Response({"detail": "Sem localização recente do motorista para iniciar."}, status=status.HTTP_409_CONFLICT)
            if dist_km > DISTANCIA_MAX_INICIO_KM:
                return Response(
                    {"detail": f"Aproxime-se do ponto de origem para iniciar (distância atual ~{dist_km:.2f}km)."},
                    status=status.HTTP_409_CONFLICT,
                )
            corrida.status = "em_andamento"
            corrida.save(update_fields=["status", "atualizado_em"])
            return Response(CorridaSerializer(corrida).data)

    @action(detail=True, methods=["post"], url_path="finalizar")
    def finalizar(self, request, pk=None):
        with transaction.atomic():
            corrida = get_object_or_404(self.get_queryset().select_for_update(), pk=pk)
            if self._corrida_expirada(corrida):
                return Response({"detail": "Corrida expirada."}, status=status.HTTP_409_CONFLICT)
            motorista_id = request.data.get("motorista_id")
            if not motorista_id:
                return Response({"detail": "motorista_id é obrigatório."}, status=status.HTTP_400_BAD_REQUEST)
            try:
                motorista = Perfil.objects.get(id=motorista_id, tipo="ecotaxista")
            except Perfil.DoesNotExist:
                return Response({"detail": "Motorista não encontrado."}, status=status.HTTP_404_NOT_FOUND)
            if motorista.user_id and request.user and request.user.is_authenticated and motorista.user_id != request.user.id:
                raise PermissionDenied("Perfil não pertence ao usuário autenticado.")
            if not corrida.motorista or corrida.motorista_id != motorista.id:
                return Response({"detail": "Corrida não atribuída a este motorista."}, status=status.HTTP_403_FORBIDDEN)
            if corrida.status != "em_andamento":
                return Response(
                    {"detail": f"Corrida não pode ser finalizada no status {corrida.status}."},
                    status=status.HTTP_409_CONFLICT,
                )
            corrida.status = "concluida"
            corrida.motoristas_tentados = []
            corrida.save(update_fields=["status", "atualizado_em", "motoristas_tentados"])
            return Response(CorridaSerializer(corrida).data)

    @action(detail=True, methods=["post"], url_path="cancelar")
    def cancelar(self, request, pk=None):
        corrida = self.get_object()
        perfil_id = request.data.get("perfil_id")
        if perfil_id:
            try:
                perfil = Perfil.objects.get(id=perfil_id)
            except Perfil.DoesNotExist:
                return Response({"detail": "Perfil não encontrado para cancelar."}, status=status.HTTP_404_NOT_FOUND)
        else:
            if not request.user or not request.user.is_authenticated:
                return Response({"detail": "perfil_id é obrigatório para cancelar."}, status=status.HTTP_400_BAD_REQUEST)
            try:
                perfil = Perfil.objects.get(user=request.user)
            except Perfil.DoesNotExist:
                return Response({"detail": "Perfil não encontrado para cancelar."}, status=status.HTTP_404_NOT_FOUND)
        if not request.user.is_staff:
            if not perfil.user_id or perfil.user_id != request.user.id:
                raise PermissionDenied("Perfil não pertence ao usuário autenticado.")
            if perfil.id != corrida.cliente_id:
                return Response({"detail": "Somente o passageiro da corrida pode cancelar."}, status=status.HTTP_403_FORBIDDEN)

        # Apenas passageiro pode cancelar; motorista deve usar rejeitar
        if perfil.tipo == "ecotaxista":
            return Response({"detail": "Motorista deve usar /rejeitar para recusar a corrida."}, status=status.HTTP_403_FORBIDDEN)

        # Bloqueios por status
        if corrida.status == "aceita":
            return Response({"detail": "Corrida já aceita pelo motorista. Não é possível cancelar agora."}, status=status.HTTP_403_FORBIDDEN)
        if corrida.status == "em_andamento":
            if datetime.now(timezone.utc) - corrida.atualizado_em < TEMPO_CANCELAMENTO_APOS_INICIO:
                return Response(
                    {"detail": "Aguarde 1 minuto após iniciar para cancelar ou finalize com o motorista."},
                    status=status.HTTP_403_FORBIDDEN,
                )

        corrida.status = "cancelada"
        corrida.motoristas_tentados = []
        corrida.save(update_fields=["status", "atualizado_em", "motoristas_tentados"])
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
        if excluir_id:
            corrida.motoristas_tentados = _limitar_motoristas_tentados(
                (corrida.motoristas_tentados or []) + [int(excluir_id)]
            )
        corrida.save(update_fields=["motorista", "status", "atualizado_em", "motoristas_tentados"])
        self._atribuir_motorista_proximo(
            corrida,
            excluir_motorista_id=int(excluir_id) if excluir_id else None,
            allow_reset=False,
        )
        return Response(CorridaSerializer(corrida).data)

    @action(detail=True, methods=["post"], url_path="rejeitar")
    def rejeitar(self, request, pk=None):
        corrida = self.get_object()
        motorista_id = request.data.get("motorista_id")
        if not motorista_id:
            return Response({"detail": "motorista_id é obrigatório."}, status=status.HTTP_400_BAD_REQUEST)
        try:
            motorista = Perfil.objects.get(id=motorista_id, tipo="ecotaxista")
        except Perfil.DoesNotExist:
            return Response({"detail": "Motorista não encontrado."}, status=status.HTTP_404_NOT_FOUND)
        if motorista.user_id and request.user and request.user.is_authenticated and motorista.user_id != request.user.id:
            raise PermissionDenied("Perfil não pertence ao usuário autenticado.")

        if corrida.status not in ["aguardando", "aceita"]:
            return Response({"detail": f"Corrida não pode ser rejeitada no status {corrida.status}."}, status=status.HTTP_409_CONFLICT)
        if corrida.motorista_id and corrida.motorista_id != motorista.id:
            return Response({"detail": "Corrida atribuída a outro motorista."}, status=status.HTTP_403_FORBIDDEN)

        corrida.motorista = None
        corrida.status = "aguardando"
        corrida.motoristas_tentados = _limitar_motoristas_tentados(
            (corrida.motoristas_tentados or []) + [motorista.id]
        )
        corrida.save(update_fields=["motorista", "status", "atualizado_em", "motoristas_tentados"])
        self._atribuir_motorista_proximo(corrida, excluir_motorista_id=motorista.id, allow_reset=False)
        return Response(CorridaSerializer(corrida).data)

    @action(detail=True, methods=["post"], url_path="status")
    def atualizar_status(self, request, pk=None):
        corrida = self.get_object()
        if not request.user.is_staff:
            return Response({"detail": "Ação restrita."}, status=status.HTTP_403_FORBIDDEN)
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
        if corrida.motorista_id and corrida.motorista_id not in (corrida.motoristas_tentados or []):
            corrida.motoristas_tentados = _limitar_motoristas_tentados(
                (corrida.motoristas_tentados or []) + [corrida.motorista_id]
            )
        corrida.status = novo_status
        corrida.save(update_fields=["status", "motorista", "atualizado_em", "motoristas_tentados"])
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
        try:
            perfil = Perfil.objects.get(id=motorista_id_int)
            if perfil.user_id and request.user and request.user.is_authenticated and perfil.user_id != request.user.id:
                return Response({}, status=status.HTTP_403_FORBIDDEN)
        except Perfil.DoesNotExist:
            return Response({}, status=status.HTTP_404_NOT_FOUND)
        if self._corrida_expirada(corrida):
            corrida.refresh_from_db()
        if not corrida.motorista_id or corrida.motorista_id != motorista_id_int or corrida.status not in ACTIVE_STATUSES:
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
        try:
            perfil = Perfil.objects.get(id=passageiro_id_int)
            if perfil.user_id and request.user and request.user.is_authenticated and perfil.user_id != request.user.id:
                return Response({}, status=status.HTTP_403_FORBIDDEN)
        except Perfil.DoesNotExist:
            return Response({}, status=status.HTTP_404_NOT_FOUND)
        if self._corrida_expirada(corrida):
            corrida.refresh_from_db()
        if corrida.status == "aguardando" and not corrida.motorista_id:
            # tenta reatribuir periodicamente até encontrar alguém
            self._atribuir_motorista_proximo(corrida, allow_reset=False)
            corrida.refresh_from_db()
        return Response(CorridaSerializer(corrida).data)


class LocalizacaoPingViewSet(viewsets.ModelViewSet):
    queryset = LocalizacaoPing.objects.select_related("perfil__user").all()
    serializer_class = LocalizacaoPingSerializer
    http_method_names = ["get", "post"]
    permission_classes = [IsAuthenticated]

    def get_queryset(self):
        qs = super().get_queryset()
        perfil_id = self.request.query_params.get("perfil_id")
        if perfil_id:
            qs = qs.filter(perfil_id=perfil_id)
        return qs.order_by("-criado_em")

    def perform_create(self, serializer):
        perfil = serializer.validated_data.get("perfil")
        user = self.request.user
        if perfil and perfil.user_id and user and user.is_authenticated and perfil.user_id != user.id:
            raise PermissionDenied("Perfil não pertence ao usuário autenticado.")
        serializer.save()


class MotoristasProximosView(APIView):
    permission_classes = [IsAuthenticated]

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
                    "device_uuid": str(ping.perfil.device_uuid),
                    "latitude": float(ping.latitude),
                    "longitude": float(ping.longitude),
                    "precisao_m": ping.precisao_m,
                    "dist_km": round(dist, 3),
                    "ping_em": ping.criado_em,
                }
            )

        return Response(resposta)

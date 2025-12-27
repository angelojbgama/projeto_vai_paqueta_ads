from django.utils import timezone
from rest_framework import serializers

from .models import Corrida, LocalizacaoPing, Perfil, UserContato


class PerfilSerializer(serializers.ModelSerializer):
    telefone = serializers.SerializerMethodField()

    class Meta:
        model = Perfil
        fields = ["id", "plataforma", "tipo", "nome", "telefone", "criado_em", "atualizado_em"]
        read_only_fields = ["id", "criado_em", "atualizado_em"]

    def get_telefone(self, obj):
        if not obj.user:
            return None
        try:
            return obj.user.contato.telefone
        except UserContato.DoesNotExist:
            return None


class CorridaSerializer(serializers.ModelSerializer):
    cliente = PerfilSerializer(read_only=True)
    motorista = PerfilSerializer(read_only=True)
    motorista_lat = serializers.SerializerMethodField()
    motorista_lng = serializers.SerializerMethodField()
    motorista_ping_em = serializers.SerializerMethodField()
    server_time = serializers.SerializerMethodField()

    class Meta:
        model = Corrida
        fields = [
            "id",
            "cliente",
            "motorista",
            "status",
            "origem_lat",
            "origem_lng",
            "origem_endereco",
            "destino_lat",
            "destino_lng",
            "destino_endereco",
            "motorista_lat",
            "motorista_lng",
            "motorista_ping_em",
            "criado_em",
            "atualizado_em",
            "server_time",
        ]
        read_only_fields = ["id", "cliente", "motorista", "status", "criado_em", "atualizado_em"]

    def _ultimo_ping(self, obj):
        if not obj.motorista:
            return None
        from .models import LocalizacaoPing

        return (
            LocalizacaoPing.objects.filter(perfil=obj.motorista)
            .order_by("-criado_em")
            .values("latitude", "longitude", "criado_em")
            .first()
        )

    def get_motorista_lat(self, obj):
        ping = self._ultimo_ping(obj)
        if not ping:
            return None
        return float(ping["latitude"])

    def get_motorista_lng(self, obj):
        ping = self._ultimo_ping(obj)
        if not ping:
            return None
        return float(ping["longitude"])

    def get_motorista_ping_em(self, obj):
        ping = self._ultimo_ping(obj)
        if not ping:
            return None
        return ping["criado_em"]

    def get_server_time(self, obj):
        return timezone.now()


class CorridaCreateSerializer(serializers.Serializer):
    perfil_id = serializers.IntegerField()
    origem_lat = serializers.DecimalField(max_digits=9, decimal_places=6)
    origem_lng = serializers.DecimalField(max_digits=9, decimal_places=6)
    origem_endereco = serializers.CharField(required=False, allow_blank=True)
    destino_lat = serializers.DecimalField(max_digits=9, decimal_places=6)
    destino_lng = serializers.DecimalField(max_digits=9, decimal_places=6)
    destino_endereco = serializers.CharField(required=False, allow_blank=True)


class CorridaStatusSerializer(serializers.Serializer):
    status = serializers.ChoiceField(choices=[s[0] for s in Corrida.STATUS_CHOICES])
    motorista_id = serializers.IntegerField(required=False)


class LocalizacaoPingSerializer(serializers.ModelSerializer):
    class Meta:
        model = LocalizacaoPing
        fields = ["id", "perfil", "latitude", "longitude", "precisao_m", "criado_em"]
        read_only_fields = ["id", "criado_em"]

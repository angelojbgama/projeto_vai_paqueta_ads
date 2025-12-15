from rest_framework import serializers

from .models import Corrida, Device, LocalizacaoPing, Perfil


class DeviceSerializer(serializers.ModelSerializer):
    class Meta:
        model = Device
        fields = ["id", "device_uuid", "plataforma", "criado_em", "ultimo_ping"]
        read_only_fields = ["id", "device_uuid", "criado_em", "ultimo_ping"]


class PerfilSerializer(serializers.ModelSerializer):
    device_uuid = serializers.UUIDField(source="device.device_uuid", read_only=True)

    class Meta:
        model = Perfil
        fields = ["id", "device", "device_uuid", "tipo", "nome", "criado_em"]
        read_only_fields = ["id", "device_uuid", "criado_em"]


class CorridaSerializer(serializers.ModelSerializer):
    cliente = PerfilSerializer(read_only=True)
    motorista = PerfilSerializer(read_only=True)

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
            "criado_em",
            "atualizado_em",
        ]
        read_only_fields = ["id", "cliente", "motorista", "status", "criado_em", "atualizado_em"]


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


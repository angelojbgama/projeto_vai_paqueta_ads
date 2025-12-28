import uuid
from django.conf import settings
from django.core.validators import MaxValueValidator, MinValueValidator
from django.db import models


class UserContato(models.Model):
    user = models.OneToOneField(
        settings.AUTH_USER_MODEL, related_name="contato", on_delete=models.CASCADE
    )
    telefone = models.CharField(max_length=30, blank=True)
    atualizado_em = models.DateTimeField(auto_now=True)

    def __str__(self):
        return f"Contato {self.user_id}"


class Perfil(models.Model):
    TIPO_CHOICES = [
        ("passageiro", "Passageiro"),
        ("ecotaxista", "EcoTaxista"),
    ]

    user = models.OneToOneField(
        settings.AUTH_USER_MODEL, related_name="perfil_app", on_delete=models.CASCADE, null=True, blank=True
    )
    device_uuid = models.UUIDField(default=uuid.uuid4, unique=True, editable=False)
    plataforma = models.CharField(max_length=50, blank=True, help_text="android, ios, web")
    tipo = models.CharField(max_length=20, choices=TIPO_CHOICES)
    nome = models.CharField(max_length=120, blank=True)
    criado_em = models.DateTimeField(auto_now_add=True)
    atualizado_em = models.DateTimeField(auto_now=True)

    def __str__(self):
        return f"{self.tipo} ({self.user_id})"


class Corrida(models.Model):
    STATUS_CHOICES = [
        ("aguardando", "Aguardando motorista"),
        ("aceita", "Aceita"),
        ("em_andamento", "Em andamento"),
        ("concluida", "Concluída"),
        ("cancelada", "Cancelada"),
        ("rejeitada", "Rejeitada"),
    ]

    cliente = models.ForeignKey(
        Perfil, related_name="corridas_cliente", on_delete=models.CASCADE
    )
    motorista = models.ForeignKey(
        Perfil,
        related_name="corridas_motorista",
        null=True,
        blank=True,
        on_delete=models.SET_NULL,
    )
    status = models.CharField(max_length=20, choices=STATUS_CHOICES, default="aguardando")
    lugares = models.PositiveSmallIntegerField(
        default=1,
        validators=[MinValueValidator(1), MaxValueValidator(2)],
        help_text="Quantidade de lugares solicitados (1-2).",
    )
    origem_lat = models.DecimalField(max_digits=9, decimal_places=6, null=True, blank=True)
    origem_lng = models.DecimalField(max_digits=9, decimal_places=6, null=True, blank=True)
    destino_lat = models.DecimalField(max_digits=9, decimal_places=6, null=True, blank=True)
    destino_lng = models.DecimalField(max_digits=9, decimal_places=6, null=True, blank=True)
    origem_endereco = models.CharField(max_length=255, blank=True)
    destino_endereco = models.CharField(max_length=255, blank=True)
    criado_em = models.DateTimeField(auto_now_add=True)
    atualizado_em = models.DateTimeField(auto_now=True)
    motoristas_tentados = models.JSONField(default=list, blank=True)

    def __str__(self):
        return f"Corrida {self.id} - {self.status}"


class LocalizacaoPing(models.Model):
    perfil = models.ForeignKey(Perfil, related_name="pings", on_delete=models.CASCADE)
    latitude = models.DecimalField(max_digits=9, decimal_places=6)
    longitude = models.DecimalField(max_digits=9, decimal_places=6)
    precisao_m = models.FloatField(null=True, blank=True)
    criado_em = models.DateTimeField(auto_now_add=True)

    def __str__(self):
        return f"Ping {self.perfil_id} ({self.latitude}, {self.longitude})"

from django.contrib import admin

from .models import Corrida, Device, LocalizacaoPing, Perfil


@admin.register(Device)
class DeviceAdmin(admin.ModelAdmin):
    list_display = ("id", "device_uuid", "plataforma", "criado_em", "ultimo_ping")
    search_fields = ("device_uuid", "plataforma")
    list_filter = ("plataforma", "criado_em")
    readonly_fields = ("criado_em", "ultimo_ping")


@admin.register(Perfil)
class PerfilAdmin(admin.ModelAdmin):
    list_display = ("id", "device", "tipo", "nome", "criado_em")
    list_filter = ("tipo", "criado_em")
    search_fields = ("nome", "device__device_uuid")
    readonly_fields = ("criado_em",)


@admin.register(Corrida)
class CorridaAdmin(admin.ModelAdmin):
    list_display = (
        "id",
        "status",
        "cliente",
        "motorista",
        "origem_lat",
        "origem_lng",
        "destino_lat",
        "destino_lng",
        "criado_em",
        "atualizado_em",
    )
    list_filter = ("status", "criado_em", "atualizado_em")
    search_fields = ("id", "cliente__device__device_uuid", "motorista__device__device_uuid")
    readonly_fields = ("criado_em", "atualizado_em")


@admin.register(LocalizacaoPing)
class LocalizacaoPingAdmin(admin.ModelAdmin):
    list_display = ("id", "perfil", "latitude", "longitude", "precisao_m", "criado_em")
    list_filter = ("criado_em", "perfil__tipo")
    search_fields = ("perfil__device__device_uuid",)
    readonly_fields = ("criado_em",)


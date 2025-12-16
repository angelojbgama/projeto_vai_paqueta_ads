from django.contrib import admin

from .models import Corrida, LocalizacaoPing, Perfil, UserContato


@admin.register(UserContato)
class UserContatoAdmin(admin.ModelAdmin):
    list_display = ("id", "user", "telefone", "atualizado_em")
    search_fields = ("user__email", "telefone")
    readonly_fields = ("atualizado_em",)


@admin.register(Perfil)
class PerfilAdmin(admin.ModelAdmin):
    list_display = ("id", "user", "device_uuid", "plataforma", "tipo", "nome", "criado_em", "atualizado_em")
    list_filter = ("tipo", "criado_em")
    search_fields = ("nome", "user__email", "device_uuid")
    readonly_fields = ("criado_em", "atualizado_em")


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
    search_fields = ("id", "cliente__user__email", "motorista__user__email")
    readonly_fields = ("criado_em", "atualizado_em")


@admin.register(LocalizacaoPing)
class LocalizacaoPingAdmin(admin.ModelAdmin):
    list_display = ("id", "perfil", "latitude", "longitude", "precisao_m", "criado_em")
    list_filter = ("criado_em", "perfil__tipo")
    search_fields = ("perfil__device_uuid",)
    readonly_fields = ("criado_em",)


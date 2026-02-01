from __future__ import annotations

from datetime import timedelta

from celery import shared_task
from django.conf import settings
from django.utils import timezone

from .constants import PING_MAX_AGE_MINUTES
from .fcm import send_push_to_tokens
from .models import Corrida, FcmDeviceToken, LocalizacaoPing, Perfil


def _ha_ecotaxista_online() -> bool:
    limite = timezone.now() - timedelta(minutes=PING_MAX_AGE_MINUTES)
    return LocalizacaoPing.objects.filter(perfil__tipo="ecotaxista", criado_em__gte=limite).exists()


def _chunked(tokens: list[str], chunk_size: int = 500):
    for i in range(0, len(tokens), chunk_size):
        yield tokens[i : i + chunk_size]


@shared_task
def notificar_sem_motoristas(corrida_id: int) -> dict:
    corrida = Corrida.objects.filter(id=corrida_id).first()
    if not corrida or corrida.status != "aguardando":
        return {"detail": "corrida_invalida"}
    if _ha_ecotaxista_online():
        return {"detail": "motoristas_online"}

    channel_id = getattr(settings, "FCM_ANDROID_CHANNEL_ID", None)
    data = {
        "type": "ride_available",
        "corrida_id": str(corrida_id),
        "payload": f"ride:{corrida_id}",
    }
    total_tokens = 0
    total_success = 0
    total_failure = 0

    perfis = Perfil.objects.filter(tipo="ecotaxista").select_related("user")
    for perfil in perfis:
        tokens = list(
            FcmDeviceToken.objects.filter(perfil=perfil, ativo=True).values_list("token", flat=True)
        )
        if not tokens:
            continue
        total_tokens += len(tokens)
        nome = (perfil.nome or (perfil.user.first_name if perfil.user else "") or "").strip()
        if not nome:
            nome = "motorista"
        body = (
            f"Olá {nome}, há uma nova corrida disponível perto de você. "
            "Abra o app Vai Paquetá para ver os detalhes."
        )
        for chunk in _chunked(tokens):
            try:
                response = send_push_to_tokens(
                    tokens=chunk,
                    title="Nova corrida disponível",
                    body=body,
                    data=data,
                    android_channel_id=channel_id,
                )
            except Exception as exc:
                return {"detail": "erro_envio", "error": str(exc)}
            if response is None:
                continue
            total_success += response.success_count
            total_failure += response.failure_count

    return {
        "detail": "ok",
        "tokens": total_tokens,
        "success": total_success,
        "failure": total_failure,
    }

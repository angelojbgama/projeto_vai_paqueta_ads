from __future__ import annotations

from typing import Iterable
from pathlib import Path

from django.conf import settings

import firebase_admin
from firebase_admin import credentials, messaging


def _init_firebase() -> None:
    if firebase_admin._apps:
        return
    cred_path = getattr(settings, "FIREBASE_SERVICE_ACCOUNT_PATH", "")
    if not cred_path:
        raise RuntimeError("FIREBASE_SERVICE_ACCOUNT_PATH não configurado.")
    path = Path(cred_path)
    if not path.is_absolute():
        path = Path(getattr(settings, "BASE_DIR", Path.cwd())) / path
    cred = credentials.Certificate(str(path))
    firebase_admin.initialize_app(cred)


def send_push_to_tokens(
    *,
    tokens: Iterable[str],
    title: str,
    body: str,
    data: dict[str, str] | None = None,
    android_channel_id: str | None = None,
) -> messaging.BatchResponse | None:
    tokens_list = [token for token in tokens if token]
    if not tokens_list:
        return None
    _init_firebase()
    notification = messaging.Notification(title=title, body=body)
    android = None
    if android_channel_id:
        android = messaging.AndroidConfig(
            priority="high",
            notification=messaging.AndroidNotification(channel_id=android_channel_id),
        )
    apns = messaging.APNSConfig(
        headers={"apns-priority": "10"},
        payload=messaging.APNSPayload(aps=messaging.Aps(sound="default")),
    )
    message = messaging.MulticastMessage(
        tokens=tokens_list,
        notification=notification,
        data=data or {},
        android=android,
        apns=apns,
    )
    return messaging.send_multicast(message)

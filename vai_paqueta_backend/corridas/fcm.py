from __future__ import annotations

from typing import Iterable
from pathlib import Path

from django.conf import settings

import firebase_admin
from firebase_admin import credentials, messaging


class _SimpleBatchResponse:
    def __init__(self, success_count: int, failure_count: int):
        self.success_count = success_count
        self.failure_count = failure_count


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
    try:
        # Prefer the per-message API to avoid /batch endpoint issues.
        send_each = getattr(messaging, "send_each_for_multicast", None)
        if send_each:
            return send_each(message)
        return messaging.send_multicast(message)
    except Exception:
        # Fallback: envia token a token.
        success = 0
        failure = 0
        for token in tokens_list:
            try:
                messaging.send(
                    messaging.Message(
                        token=token,
                        notification=notification,
                        data=data or {},
                        android=android,
                        apns=apns,
                    )
                )
                success += 1
            except Exception:
                failure += 1
        return _SimpleBatchResponse(success, failure)

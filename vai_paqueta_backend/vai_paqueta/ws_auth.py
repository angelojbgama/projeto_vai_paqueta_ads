from __future__ import annotations

from http import cookies
from typing import Optional
from urllib.parse import parse_qs

from channels.db import database_sync_to_async
from channels.middleware import BaseMiddleware
from django.contrib.auth.models import AnonymousUser
from rest_framework_simplejwt.authentication import JWTAuthentication
from rest_framework_simplejwt.exceptions import InvalidToken, TokenError


def _parse_cookies(header_value: str) -> dict[str, str]:
    jar = cookies.SimpleCookie()
    jar.load(header_value or "")
    return {key: morsel.value for key, morsel in jar.items()}


class JWTAuthMiddleware(BaseMiddleware):
    def __init__(self, inner):
        super().__init__(inner)
        self._jwt = JWTAuthentication()

    async def __call__(self, scope, receive, send):
        scope["user"] = AnonymousUser()
        token = self._extract_token(scope)
        if token:
            user = await self._get_user(token)
            if user:
                scope["user"] = user
        return await super().__call__(scope, receive, send)

    def _extract_token(self, scope) -> Optional[str]:
        query_string = (scope.get("query_string") or b"").decode("utf-8")
        query_params = parse_qs(query_string)
        token = None
        for key in ("token", "access", "access_token"):
            if key in query_params and query_params[key]:
                token = query_params[key][0]
                break

        headers = {k.lower(): v for k, v in (scope.get("headers") or [])}
        auth_header = headers.get(b"authorization")
        if auth_header:
            try:
                parts = auth_header.decode("utf-8").split()
            except UnicodeDecodeError:
                parts = []
            if len(parts) == 2 and parts[0].lower() == "bearer":
                token = parts[1]

        if not token and b"cookie" in headers:
            cookie_header = headers[b"cookie"].decode("utf-8", errors="ignore")
            cookie_data = _parse_cookies(cookie_header)
            token = cookie_data.get("access_token")

        return token

    @database_sync_to_async
    def _get_user(self, raw_token: str):
        try:
            validated = self._jwt.get_validated_token(raw_token)
            return self._jwt.get_user(validated)
        except (InvalidToken, TokenError, Exception):
            return None

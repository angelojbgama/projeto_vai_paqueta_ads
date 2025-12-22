import uuid

from django.conf import settings
from django.contrib.auth import authenticate
from django.contrib.auth.models import User
from rest_framework import status
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework.throttling import ScopedRateThrottle
from rest_framework.views import APIView
from rest_framework_simplejwt.serializers import TokenRefreshSerializer
from rest_framework_simplejwt.tokens import RefreshToken, TokenError

from corridas.models import Perfil, UserContato


def _perfil_para_usuario(user: User) -> Perfil:
    perfil, _ = Perfil.objects.get_or_create(
        user=user, defaults={"tipo": "passageiro", "nome": user.first_name, "plataforma": ""}
    )
    return perfil


def _user_payload(user: User) -> dict:
    telefone = ""
    try:
        telefone = user.contato.telefone
    except UserContato.DoesNotExist:
        telefone = ""
    perfil = _perfil_para_usuario(user)
    return {
        "id": user.id,
        "email": user.email,
        "nome": user.first_name or "",
        "telefone": telefone,
        "perfil_id": perfil.id,
        "perfil_tipo": perfil.tipo,
        "device_plataforma": perfil.plataforma,
    }


def _token_payload(user: User) -> dict:
    refresh = RefreshToken.for_user(user)
    return {
        "access": str(refresh.access_token),
        "refresh": str(refresh),
    }


def _set_jwt_cookies(response: Response, tokens: dict) -> None:
    access = tokens.get("access")
    refresh = tokens.get("refresh")
    if not access or not refresh:
        return
    access_max_age = int(settings.SIMPLE_JWT["ACCESS_TOKEN_LIFETIME"].total_seconds())
    refresh_max_age = int(settings.SIMPLE_JWT["REFRESH_TOKEN_LIFETIME"].total_seconds())
    cookie_kwargs = {
        "httponly": True,
        "secure": settings.JWT_COOKIE_SECURE,
        "samesite": settings.JWT_COOKIE_SAMESITE,
        "path": settings.JWT_COOKIE_PATH,
    }
    if settings.JWT_COOKIE_DOMAIN:
        cookie_kwargs["domain"] = settings.JWT_COOKIE_DOMAIN
    response.set_cookie("access_token", access, max_age=access_max_age, **cookie_kwargs)
    response.set_cookie("refresh_token", refresh, max_age=refresh_max_age, **cookie_kwargs)


def _clear_jwt_cookies(response: Response) -> None:
    cookie_kwargs = {
        "path": settings.JWT_COOKIE_PATH,
    }
    if settings.JWT_COOKIE_DOMAIN:
        cookie_kwargs["domain"] = settings.JWT_COOKIE_DOMAIN
    response.delete_cookie("access_token", **cookie_kwargs)
    response.delete_cookie("refresh_token", **cookie_kwargs)


class RegisterView(APIView):
    permission_classes = []
    authentication_classes = []
    throttle_classes = [ScopedRateThrottle]
    throttle_scope = "auth"

    def post(self, request):
        use_cookies = request.headers.get("X-Use-Cookies") == "1" or bool(request.data.get("use_cookies"))
        email = (request.data.get("email") or "").strip().lower()
        password = request.data.get("password") or ""
        nome = (request.data.get("nome") or "").strip()
        telefone = (request.data.get("telefone") or "").strip()
        tipo = (request.data.get("tipo") or "passageiro").strip() or "passageiro"
        device_uuid = (request.data.get("device_uuid") or "").strip()
        plataforma = (request.data.get("plataforma") or "").strip()

        if not email or not password or not telefone or not nome:
            return Response(
                {"detail": "nome, telefone, email e password são obrigatórios."},
                status=status.HTTP_400_BAD_REQUEST,
            )
        if len(password) < 6:
            return Response({"detail": "Senha deve ter ao menos 6 caracteres."}, status=status.HTTP_400_BAD_REQUEST)
        if User.objects.filter(email=email).exists():
            return Response({"detail": "E-mail já cadastrado."}, status=status.HTTP_409_CONFLICT)

        user = User.objects.create_user(username=email, email=email, password=password, first_name=nome)
        UserContato.objects.update_or_create(user=user, defaults={"telefone": telefone})
        perfil_defaults = {"tipo": tipo if tipo in dict(Perfil.TIPO_CHOICES) else "passageiro", "nome": nome}
        if plataforma:
            perfil_defaults["plataforma"] = plataforma
        perfil = _perfil_para_usuario(user)
        for key, value in perfil_defaults.items():
            setattr(perfil, key, value)
        if device_uuid:
            try:
                perfil.device_uuid = uuid.UUID(device_uuid)
            except ValueError:
                pass
        perfil.save()
        tokens = _token_payload(user)
        payload = {"user": _user_payload(user)}
        if not use_cookies:
            payload["tokens"] = tokens
        response = Response(payload, status=status.HTTP_201_CREATED)
        if use_cookies:
            _set_jwt_cookies(response, tokens)
        return response


class LoginView(APIView):
    permission_classes = []
    authentication_classes = []
    throttle_classes = [ScopedRateThrottle]
    throttle_scope = "auth"

    def post(self, request):
        use_cookies = request.headers.get("X-Use-Cookies") == "1" or bool(request.data.get("use_cookies"))
        email = (request.data.get("email") or "").strip().lower()
        password = request.data.get("password") or ""
        if not email or not password:
            return Response({"detail": "email e password são obrigatórios."}, status=status.HTTP_400_BAD_REQUEST)
        user = authenticate(username=email, password=password)
        if not user:
            return Response({"detail": "Credenciais inválidas."}, status=status.HTTP_401_UNAUTHORIZED)
        _perfil_para_usuario(user)
        tokens = _token_payload(user)
        payload = {"user": _user_payload(user)}
        if not use_cookies:
            payload["tokens"] = tokens
        response = Response(payload, status=status.HTTP_200_OK)
        if use_cookies:
            _set_jwt_cookies(response, tokens)
        return response


class MeView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request):
        user: User = request.user
        return Response({"user": _user_payload(user)})

    def patch(self, request):
        """
        Atualiza dados básicos do usuário autenticado (tipo, nome, telefone).
        """
        user: User = request.user
        nome = (request.data.get("nome") or "").strip()
        telefone = (request.data.get("telefone") or "").strip()
        tipo = (request.data.get("tipo") or "").strip()
        plataforma = (request.data.get("plataforma") or "").strip()

        if nome:
            user.first_name = nome
            user.save(update_fields=["first_name"])

        if telefone:
            UserContato.objects.update_or_create(user=user, defaults={"telefone": telefone})

        perfil = _perfil_para_usuario(user)
        if tipo and tipo in dict(Perfil.TIPO_CHOICES):
            perfil.tipo = tipo
        if plataforma:
            perfil.plataforma = plataforma
        perfil.save()

        return Response({"user": _user_payload(user)})


class LogoutView(APIView):
    permission_classes = []
    authentication_classes = []
    throttle_classes = [ScopedRateThrottle]
    throttle_scope = "auth"

    def post(self, request):
        refresh = request.data.get("refresh") or request.COOKIES.get("refresh_token") or ""
        if not refresh:
            response = Response({"detail": "refresh é obrigatório."}, status=status.HTTP_400_BAD_REQUEST)
            _clear_jwt_cookies(response)
            return response
        try:
            token = RefreshToken(refresh)
            token.blacklist()
        except TokenError:
            response = Response({"detail": "refresh inválido."}, status=status.HTTP_400_BAD_REQUEST)
            _clear_jwt_cookies(response)
            return response
        response = Response({"detail": "Logout realizado."}, status=status.HTTP_200_OK)
        _clear_jwt_cookies(response)
        return response


class CookieTokenRefreshView(APIView):
    permission_classes = []
    authentication_classes = []
    throttle_classes = [ScopedRateThrottle]
    throttle_scope = "auth"

    def post(self, request):
        data = {}
        if isinstance(request.data, dict):
            data = request.data.copy()
        refresh_cookie = request.COOKIES.get("refresh_token")
        used_cookie = False
        if not data.get("refresh") and refresh_cookie:
            data["refresh"] = refresh_cookie
            used_cookie = True
        if not data.get("refresh"):
            return Response({"detail": "refresh é obrigatório."}, status=status.HTTP_400_BAD_REQUEST)
        serializer = TokenRefreshSerializer(data=data)
        serializer.is_valid(raise_exception=True)
        tokens = serializer.validated_data
        response_data = {"detail": "ok"} if used_cookie else tokens
        response = Response(response_data, status=status.HTTP_200_OK)
        if used_cookie:
            refresh_value = tokens.get("refresh") or refresh_cookie
            _set_jwt_cookies(response, {"access": tokens.get("access"), "refresh": refresh_value})
        return response

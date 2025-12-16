import uuid

from django.contrib.auth import authenticate
from django.contrib.auth.models import User
from rest_framework import status
from rest_framework.authtoken.models import Token
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView

from corridas.models import Perfil, UserContato


def _perfil_para_usuario(user: User) -> Perfil:
    perfil, _ = Perfil.objects.get_or_create(
        user=user, defaults={"tipo": "passageiro", "nome": user.first_name, "plataforma": ""}
    )
    return perfil


def _user_payload(user: User, token: Token | None = None) -> dict:
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
        "device_uuid": str(perfil.device_uuid),
        "device_plataforma": perfil.plataforma,
        "token": token.key if token else None,
    }


class RegisterView(APIView):
    permission_classes = []
    authentication_classes = []

    def post(self, request):
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
        token, _ = Token.objects.get_or_create(user=user)
        return Response({"user": _user_payload(user, token)}, status=status.HTTP_201_CREATED)


class LoginView(APIView):
    permission_classes = []
    authentication_classes = []

    def post(self, request):
        email = (request.data.get("email") or "").strip().lower()
        password = request.data.get("password") or ""
        if not email or not password:
            return Response({"detail": "email e password são obrigatórios."}, status=status.HTTP_400_BAD_REQUEST)
        user = authenticate(username=email, password=password)
        if not user:
            return Response({"detail": "Credenciais inválidas."}, status=status.HTTP_401_UNAUTHORIZED)
        _perfil_para_usuario(user)
        token, _ = Token.objects.get_or_create(user=user)
        return Response({"user": _user_payload(user, token)}, status=status.HTTP_200_OK)


class MeView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request):
        user: User = request.user
        return Response({"user": _user_payload(user)})

    def patch(self, request):
        """
        Atualiza dados básicos do usuário autenticado (tipo, nome, telefone, device).
        """
        user: User = request.user
        nome = (request.data.get("nome") or "").strip()
        telefone = (request.data.get("telefone") or "").strip()
        tipo = (request.data.get("tipo") or "").strip()
        device_uuid = (request.data.get("device_uuid") or "").strip()
        plataforma = (request.data.get("plataforma") or "").strip()

        if nome:
            user.first_name = nome
            user.save(update_fields=["first_name"])

        if telefone:
            UserContato.objects.update_or_create(user=user, defaults={"telefone": telefone})

        perfil = _perfil_para_usuario(user)
        if tipo and tipo in dict(Perfil.TIPO_CHOICES):
            perfil.tipo = tipo
        if device_uuid:
            try:
                perfil.device_uuid = uuid.UUID(device_uuid)
            except ValueError:
                return Response({"detail": "device_uuid inválido."}, status=status.HTTP_400_BAD_REQUEST)
        if plataforma:
            perfil.plataforma = plataforma
        perfil.save()

        return Response({"user": _user_payload(user)})

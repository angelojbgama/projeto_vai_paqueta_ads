from django.contrib.auth import authenticate
from django.contrib.auth.models import User
from rest_framework import status
from rest_framework.authtoken.models import Token
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView


def _user_payload(user: User, token: Token | None = None) -> dict:
    return {
        "id": user.id,
        "email": user.email,
        "nome": user.first_name or "",
        "token": token.key if token else None,
    }


class RegisterView(APIView):
    permission_classes = []
    authentication_classes = []

    def post(self, request):
        email = (request.data.get("email") or "").strip().lower()
        password = request.data.get("password") or ""
        nome = (request.data.get("nome") or "").strip()

        if not email or not password:
            return Response({"detail": "email e password são obrigatórios."}, status=status.HTTP_400_BAD_REQUEST)
        if len(password) < 6:
            return Response({"detail": "Senha deve ter ao menos 6 caracteres."}, status=status.HTTP_400_BAD_REQUEST)
        if User.objects.filter(email=email).exists():
            return Response({"detail": "E-mail já cadastrado."}, status=status.HTTP_409_CONFLICT)

        user = User.objects.create_user(username=email, email=email, password=password, first_name=nome)
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
        token, _ = Token.objects.get_or_create(user=user)
        return Response({"user": _user_payload(user, token)}, status=status.HTTP_200_OK)


class MeView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request):
        user: User = request.user
        return Response({"user": _user_payload(user)})

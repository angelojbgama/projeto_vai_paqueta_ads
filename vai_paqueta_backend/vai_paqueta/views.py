from django.shortcuts import render
from django.views.decorators.csrf import ensure_csrf_cookie
from corridas.models import Corrida, Perfil


def landing(request):
    ecotaxistas_count = Perfil.objects.filter(tipo="ecotaxista").count()
    passageiros_count = Perfil.objects.filter(tipo="passageiro").count()
    corridas_concluidas_count = Corrida.objects.filter(status="concluida").count()
    return render(
        request,
        "landing/index.html",
        {
            "ecotaxistas_count": ecotaxistas_count,
            "passageiros_count": passageiros_count,
            "corridas_concluidas_count": corridas_concluidas_count,
        },
    )


@ensure_csrf_cookie
def webapp(request):
    return render(request, "webapp/index.html")


def privacy(request):
    return render(request, "landing/privacy.html")


def tutorial(request):
    return render(request, "landing/tutorial.html")

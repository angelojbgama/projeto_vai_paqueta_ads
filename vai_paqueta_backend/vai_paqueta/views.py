from django.contrib.staticfiles import finders
from django.contrib.staticfiles.storage import staticfiles_storage
from django.http import Http404, HttpResponse
from django.shortcuts import render
from django.views.decorators.cache import cache_control
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


def _static_file_response(path, content_type):
    if staticfiles_storage.exists(path):
        with staticfiles_storage.open(path) as static_file:
            return HttpResponse(static_file.read(), content_type=content_type)
    file_path = finders.find(path)
    if not file_path:
        raise Http404(f"Arquivo estatico nao encontrado: {path}")
    with open(file_path, "rb") as static_file:
        return HttpResponse(static_file.read(), content_type=content_type)


@cache_control(no_cache=True, must_revalidate=True, no_store=True)
def webapp_manifest(request):
    return _static_file_response("pwa/manifest.json", "application/manifest+json")


@cache_control(no_cache=True, must_revalidate=True, no_store=True)
def webapp_service_worker(request):
    response = _static_file_response("pwa/sw.js", "application/javascript")
    response["Service-Worker-Allowed"] = "/app/"
    return response

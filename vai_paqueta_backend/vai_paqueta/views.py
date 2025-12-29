from django.shortcuts import render
from django.views.decorators.csrf import ensure_csrf_cookie


def landing(request):
    return render(request, "landing/index.html")


@ensure_csrf_cookie
def webapp(request):
    return render(request, "webapp/index.html")


def privacy(request):
    return render(request, "landing/privacy.html")

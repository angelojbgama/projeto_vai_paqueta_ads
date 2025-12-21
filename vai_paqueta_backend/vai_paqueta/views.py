from django.shortcuts import render


def landing(request):
    return render(request, "landing/index.html")


def webapp(request):
    return render(request, "webapp/index.html")

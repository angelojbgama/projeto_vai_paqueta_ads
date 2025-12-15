import uuid
from django.db import migrations, models
import django.db.models.deletion


class Migration(migrations.Migration):
    initial = True

    dependencies = []

    operations = [
        migrations.CreateModel(
            name="Device",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("device_uuid", models.UUIDField(default=uuid.uuid4, editable=False, unique=True)),
                ("plataforma", models.CharField(blank=True, help_text="android, ios, web", max_length=50)),
                ("criado_em", models.DateTimeField(auto_now_add=True)),
                ("ultimo_ping", models.DateTimeField(auto_now=True)),
            ],
        ),
        migrations.CreateModel(
            name="Perfil",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("tipo", models.CharField(choices=[("cliente", "Cliente"), ("ecotaxista", "EcoTaxista")], max_length=20)),
                ("nome", models.CharField(blank=True, max_length=120)),
                ("criado_em", models.DateTimeField(auto_now_add=True)),
                (
                    "device",
                    models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name="perfis", to="corridas.device"),
                ),
            ],
        ),
        migrations.CreateModel(
            name="Corrida",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                (
                    "status",
                    models.CharField(
                        choices=[
                            ("aguardando", "Aguardando motorista"),
                            ("aceita", "Aceita"),
                            ("em_andamento", "Em andamento"),
                            ("concluida", "Concluída"),
                            ("cancelada", "Cancelada"),
                            ("rejeitada", "Rejeitada"),
                        ],
                        default="aguardando",
                        max_length=20,
                    ),
                ),
                ("origem_lat", models.DecimalField(blank=True, decimal_places=6, max_digits=9, null=True)),
                ("origem_lng", models.DecimalField(blank=True, decimal_places=6, max_digits=9, null=True)),
                ("destino_lat", models.DecimalField(blank=True, decimal_places=6, max_digits=9, null=True)),
                ("destino_lng", models.DecimalField(blank=True, decimal_places=6, max_digits=9, null=True)),
                ("origem_endereco", models.CharField(blank=True, max_length=255)),
                ("destino_endereco", models.CharField(blank=True, max_length=255)),
                ("criado_em", models.DateTimeField(auto_now_add=True)),
                ("atualizado_em", models.DateTimeField(auto_now=True)),
                (
                    "cliente",
                    models.ForeignKey(
                        on_delete=django.db.models.deletion.CASCADE, related_name="corridas_cliente", to="corridas.perfil"
                    ),
                ),
                (
                    "motorista",
                    models.ForeignKey(
                        blank=True,
                        null=True,
                        on_delete=django.db.models.deletion.SET_NULL,
                        related_name="corridas_motorista",
                        to="corridas.perfil",
                    ),
                ),
            ],
        ),
        migrations.CreateModel(
            name="LocalizacaoPing",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("latitude", models.DecimalField(decimal_places=6, max_digits=9)),
                ("longitude", models.DecimalField(decimal_places=6, max_digits=9)),
                ("precisao_m", models.FloatField(blank=True, null=True)),
                ("criado_em", models.DateTimeField(auto_now_add=True)),
                (
                    "perfil",
                    models.ForeignKey(
                        on_delete=django.db.models.deletion.CASCADE, related_name="pings", to="corridas.perfil"
                    ),
                ),
            ],
        ),
    ]


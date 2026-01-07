# Generated manually because makemigrations não está disponível no ambiente
import django.db.models.deletion
from django.conf import settings
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        migrations.swappable_dependency(settings.AUTH_USER_MODEL),
        ("corridas", "0003_alter_perfil_tipo"),
    ]

    operations = [
        migrations.CreateModel(
            name="UserContato",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("telefone", models.CharField(blank=True, max_length=30)),
                ("atualizado_em", models.DateTimeField(auto_now=True)),
                (
                    "user",
                    models.OneToOneField(
                        on_delete=django.db.models.deletion.CASCADE,
                        related_name="contato",
                        to=settings.AUTH_USER_MODEL,
                    ),
                ),
            ],
        ),
    ]

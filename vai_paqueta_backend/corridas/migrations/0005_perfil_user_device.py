# Generated manually to mover device/perfil para o usuário
import uuid
import django.db.models.deletion
from django.conf import settings
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("corridas", "0004_usercontato"),
        migrations.swappable_dependency(settings.AUTH_USER_MODEL),
    ]

    operations = [
        migrations.RemoveField(
            model_name="perfil",
            name="device",
        ),
        migrations.DeleteModel(
            name="Device",
        ),
        migrations.AddField(
            model_name="perfil",
            name="atualizado_em",
            field=models.DateTimeField(auto_now=True),
        ),
        migrations.AddField(
            model_name="perfil",
            name="device_uuid",
            field=models.UUIDField(default=uuid.uuid4, editable=False, unique=True),
        ),
        migrations.AddField(
            model_name="perfil",
            name="plataforma",
            field=models.CharField(blank=True, help_text="android, ios, web", max_length=50),
        ),
        migrations.AddField(
            model_name="perfil",
            name="user",
            field=models.OneToOneField(
                blank=True,
                null=True,
                on_delete=django.db.models.deletion.CASCADE,
                related_name="perfil_app",
                to=settings.AUTH_USER_MODEL,
            ),
        ),
    ]

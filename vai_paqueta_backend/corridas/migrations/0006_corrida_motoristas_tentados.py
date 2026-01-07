# Generated manually to rastrear motoristas já tentados
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("corridas", "0005_perfil_user_device"),
    ]

    operations = [
        migrations.AddField(
            model_name="corrida",
            name="motoristas_tentados",
            field=models.JSONField(blank=True, default=list),
        ),
    ]

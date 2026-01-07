# Registro de timestamps por status da corrida.
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("corridas", "0007_corrida_lugares"),
    ]

    operations = [
        migrations.AddField(
            model_name="corrida",
            name="aceita_em",
            field=models.DateTimeField(blank=True, null=True),
        ),
        migrations.AddField(
            model_name="corrida",
            name="iniciada_em",
            field=models.DateTimeField(blank=True, null=True),
        ),
        migrations.AddField(
            model_name="corrida",
            name="concluida_em",
            field=models.DateTimeField(blank=True, null=True),
        ),
    ]

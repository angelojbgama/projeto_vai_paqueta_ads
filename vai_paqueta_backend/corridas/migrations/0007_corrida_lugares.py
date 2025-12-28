# Generated manually to store number of seats requested.
from django.db import migrations, models
import django.core.validators


class Migration(migrations.Migration):

    dependencies = [
        ("corridas", "0006_corrida_motoristas_tentados"),
    ]

    operations = [
        migrations.AddField(
            model_name="corrida",
            name="lugares",
            field=models.PositiveSmallIntegerField(
                default=1,
                help_text="Quantidade de lugares solicitados (1-2).",
                validators=[
                    django.core.validators.MinValueValidator(1),
                    django.core.validators.MaxValueValidator(2),
                ],
            ),
        ),
    ]

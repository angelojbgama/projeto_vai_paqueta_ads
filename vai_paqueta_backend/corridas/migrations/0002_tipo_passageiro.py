from django.db import migrations


def migrate_cliente_para_passageiro(apps, schema_editor):
    Perfil = apps.get_model("corridas", "Perfil")
    Perfil.objects.filter(tipo="cliente").update(tipo="passageiro")


class Migration(migrations.Migration):
    dependencies = [
        ("corridas", "0001_initial"),
    ]

    operations = [
        migrations.RunPython(migrate_cliente_para_passageiro, migrations.RunPython.noop),
    ]


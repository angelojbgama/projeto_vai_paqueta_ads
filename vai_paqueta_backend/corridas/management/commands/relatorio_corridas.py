import base64
import csv
import math
from datetime import datetime, time
from pathlib import Path

from django.conf import settings
from django.core.management.base import BaseCommand, CommandError
from django.utils import timezone
from django.utils.dateparse import parse_date, parse_datetime

from corridas.models import Corrida, LocalizacaoPing, UserContato


class Command(BaseCommand):
    help = "Gera um relatório detalhado (CSV) das corridas concluídas."

    def add_arguments(self, parser):
        parser.add_argument(
            "--inicio",
            dest="inicio",
            help="Data/hora mínima (ISO 8601) para filtrar por criado_em (ex: 2024-01-01 ou 2024-01-01T08:00).",
        )
        parser.add_argument(
            "--fim",
            dest="fim",
            help="Data/hora máxima (ISO 8601) para filtrar por criado_em (ex: 2024-01-31 ou 2024-01-31T23:59).",
        )
        parser.add_argument(
            "--saida",
            dest="saida",
            help="Caminho do arquivo CSV de saída. Padrão: BASE_DIR/relatorios/corridas_concluidas_<timestamp>.csv",
        )
        parser.add_argument(
            "--limite",
            dest="limite",
            type=int,
            help="Limita a quantidade exportada (útil para testes).",
        )
        parser.add_argument(
            "--plot-dir",
            dest="plot_dir",
            help="Se informado, salva um SVG por corrida com o trajeto do motorista (pings entre início e fim).",
        )
        parser.add_argument(
            "--tile-dir",
            dest="tile_dir",
            help="Diretório base das tiles (formato z/x/y.png). Padrão: static/landing/assets/tiles se existir.",
        )
        parser.add_argument(
            "--tile-zoom",
            dest="tile_zoom",
            type=int,
            default=16,
            help="Zoom das tiles a serem usadas (padrão: 16).",
        )

    def handle(self, *args, **options):
        inicio = self._parse_datetime_arg(options.get("inicio"), is_end=False) if options.get("inicio") else None
        fim = self._parse_datetime_arg(options.get("fim"), is_end=True) if options.get("fim") else None
        limite = options.get("limite")
        output_path = self._resolve_output_path(options.get("saida"))
        plot_dir = options.get("plot_dir")
        plot_path = Path(plot_dir).expanduser() if plot_dir else None
        if plot_path and not plot_path.is_absolute():
            plot_path = (Path(settings.BASE_DIR) / plot_path).resolve()
        if plot_path:
            plot_path.mkdir(parents=True, exist_ok=True)
        tile_root = self._resolve_tile_root(options.get("tile_dir"))
        tile_zoom = int(options.get("tile_zoom") or 16)

        queryset = Corrida.objects.filter(status="concluida").select_related(
            "cliente__user",
            "motorista__user",
            "cliente__user__contato",
            "motorista__user__contato",
        )
        if inicio:
            queryset = queryset.filter(criado_em__gte=inicio)
        if fim:
            queryset = queryset.filter(criado_em__lte=fim)
        queryset = queryset.order_by("criado_em")
        if limite:
            queryset = queryset[:limite]

        exportados, duracao_media = self._exportar_csv(queryset, output_path, plot_path, tile_root, tile_zoom)
        if exportados == 0:
            self.stdout.write(self.style.WARNING("Nenhuma corrida concluída encontrada para os filtros informados."))
            return

        resumo = f"{exportados} corrida(s) concluída(s) exportadas para {output_path}"
        if duracao_media is not None:
            resumo += f" | duração média: {duracao_media:.2f} min"
        self.stdout.write(self.style.SUCCESS(resumo))

    def _parse_datetime_arg(self, valor: str, is_end: bool = False) -> datetime:
        dt = parse_datetime(valor)
        if dt is None:
            data = parse_date(valor)
            if data is None:
                raise CommandError(f"Não foi possível interpretar a data/hora: {valor}")
            base_time = time.max if is_end else time.min
            dt = datetime.combine(data, base_time)
        if timezone.is_naive(dt):
            dt = timezone.make_aware(dt, timezone.get_current_timezone())
        return dt

    def _resolve_output_path(self, saida: str | None) -> Path:
        if saida:
            caminho = Path(saida).expanduser()
            if not caminho.is_absolute():
                caminho = (Path(settings.BASE_DIR) / caminho).resolve()
        else:
            timestamp = timezone.now().strftime("%Y%m%d_%H%M%S")
            caminho = Path(settings.BASE_DIR) / "relatorios" / f"corridas_concluidas_{timestamp}.csv"
        caminho.parent.mkdir(parents=True, exist_ok=True)
        return caminho

    def _telefone_perfil(self, perfil) -> str:
        if not perfil or not getattr(perfil, "user_id", None):
            return ""
        try:
            contato = perfil.user.contato
        except UserContato.DoesNotExist:
            return ""
        return contato.telefone or ""

    def _format_decimal(self, valor):
        if valor is None:
            return ""
        return f"{float(valor):.6f}"

    def _iso_or_blank(self, valor):
        if not valor:
            return ""
        return valor.isoformat()

    def _diff_minutes(self, inicio: datetime | None, fim: datetime | None) -> float | None:
        if not inicio or not fim:
            return None
        return (fim - inicio).total_seconds() / 60

    def _latlng_to_pixel(self, lat: float, lng: float, zoom: int) -> tuple[float, float]:
        lat = max(min(lat, 85.05112878), -85.05112878)
        n = 2**zoom
        x = (lng + 180.0) / 360.0
        lat_rad = math.radians(lat)
        y = (1 - math.log(math.tan(lat_rad) + 1 / math.cos(lat_rad)) / math.pi) / 2
        return x * n * 256, y * n * 256

    def _resolve_tile_root(self, tile_dir: str | None) -> Path | None:
        if tile_dir:
            root = Path(tile_dir).expanduser()
            if not root.is_absolute():
                root = (Path(settings.BASE_DIR) / root).resolve()
        else:
            root = Path(settings.BASE_DIR) / "static" / "landing" / "assets" / "tiles"
        if root.exists():
            return root
        return None

    def _pings_da_corrida(self, corrida: Corrida):
        if not corrida.motorista_id:
            return []
        inicio = corrida.iniciada_em or corrida.aceita_em or corrida.criado_em
        fim = corrida.concluida_em or corrida.atualizado_em
        if not inicio or not fim:
            return []
        return list(
            LocalizacaoPing.objects.filter(
                perfil_id=corrida.motorista_id,
                criado_em__gte=inicio,
                criado_em__lte=fim,
            )
            .order_by("criado_em")
            .values_list("latitude", "longitude", "criado_em")
        )

    def _gerar_svg_trajeto(self, corrida: Corrida, pings, plot_dir: Path | None, tile_root: Path | None, tile_zoom: int):
        if not plot_dir or not pings:
            return None

        lats = [float(p[0]) for p in pings]
        lngs = [float(p[1]) for p in pings]
        times = [p[2] for p in pings]

        # Converte para pixels globais no esquema WebMercator para alinhar com tiles.
        pixels = [self._latlng_to_pixel(lat, lng, tile_zoom) for lat, lng in zip(lats, lngs)]
        px_vals = [p[0] for p in pixels]
        py_vals = [p[1] for p in pixels]
        if not px_vals or not py_vals:
            return None

        n_tiles = 2**tile_zoom
        margin_tiles = 1
        tile_min_x = max(0, int(math.floor(min(px_vals) / 256)) - margin_tiles)
        tile_max_x = min(n_tiles - 1, int(math.floor(max(px_vals) / 256)) + margin_tiles)
        tile_min_y = max(0, int(math.floor(min(py_vals) / 256)) - margin_tiles)
        tile_max_y = min(n_tiles - 1, int(math.floor(max(py_vals) / 256)) + margin_tiles)

        width = (tile_max_x - tile_min_x + 1) * 256
        height = (tile_max_y - tile_min_y + 1) * 256
        offset_x = tile_min_x * 256
        offset_y = tile_min_y * 256

        coords = []
        for px, py in pixels:
            coords.append((px - offset_x, py - offset_y))
        path_data = " ".join(f"{x:.2f},{y:.2f}" for x, y in coords)
        inicio_txt = times[0].isoformat() if times else ""
        fim_txt = times[-1].isoformat() if times else ""

        # Monta background com tiles locais (se existirem).
        images_svg = []
        if tile_root:
            for tile_x in range(tile_min_x, tile_max_x + 1):
                for tile_y in range(tile_min_y, tile_max_y + 1):
                    tile_path = tile_root / str(tile_zoom) / str(tile_x) / f"{tile_y}.png"
                    if not tile_path.exists():
                        continue
                    try:
                        data = tile_path.read_bytes()
                    except OSError:
                        continue
                    encoded = base64.b64encode(data).decode("ascii")
                    href = f"data:image/png;base64,{encoded}"
                    x = (tile_x - tile_min_x) * 256
                    y = (tile_y - tile_min_y) * 256
                    images_svg.append(
                        f'<image href="{href}" x="{x}" y="{y}" width="256" height="256" preserveAspectRatio="none" />'
                    )

        svg = [
            f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">',
            '<rect width="100%" height="100%" fill="#f8fafc" />',
        ]
        svg.extend(images_svg)
        svg.append(f'<polyline points="{path_data}" fill="none" stroke="#0f172a" stroke-width="2" stroke-linejoin="round" stroke-linecap="round" />')
        svg.append(f'<circle cx="{coords[0][0]:.2f}" cy="{coords[0][1]:.2f}" r="5" fill="#22c55e" stroke="#14532d" />')
        svg.append(f'<circle cx="{coords[-1][0]:.2f}" cy="{coords[-1][1]:.2f}" r="5" fill="#ef4444" stroke="#7f1d1d" />')
        svg.append(f'<text x="12" y="{height - 20}" font-size="12" fill="#334155" font-family="sans-serif">Início: {inicio_txt}</text>')
        svg.append(f'<text x="12" y="{height - 6}" font-size="12" fill="#334155" font-family="sans-serif">Fim: {fim_txt}</text>')
        svg.append("</svg>")

        destino = plot_dir / f"corrida_{corrida.id}_trajeto.svg"
        destino.write_text("\n".join(svg), encoding="utf-8")
        return destino

    def _linha_corrida(self, corrida: Corrida, plot_dir: Path | None, tile_root: Path | None, tile_zoom: int):
        pings = self._pings_da_corrida(corrida)
        trajeto_svg = self._gerar_svg_trajeto(corrida, pings, plot_dir, tile_root, tile_zoom)
        concluida_em = corrida.concluida_em or corrida.atualizado_em
        duracao_min = self._diff_minutes(corrida.criado_em, concluida_em)
        tempo_ate_aceite = self._diff_minutes(corrida.criado_em, corrida.aceita_em)
        tempo_ate_inicio = None
        if corrida.iniciada_em:
            base_inicio = corrida.aceita_em or corrida.criado_em
            tempo_ate_inicio = self._diff_minutes(base_inicio, corrida.iniciada_em)
        tempo_em_andamento = self._diff_minutes(corrida.iniciada_em, concluida_em)

        linha = {
            "corrida_id": corrida.id,
            "status": corrida.status,
            "criado_em": self._iso_or_blank(corrida.criado_em),
            "atualizado_em": self._iso_or_blank(corrida.atualizado_em),
            "aceita_em": self._iso_or_blank(corrida.aceita_em),
            "iniciada_em": self._iso_or_blank(corrida.iniciada_em),
            "concluida_em": self._iso_or_blank(corrida.concluida_em),
            "duracao_minutos": round(duracao_min, 2) if duracao_min is not None else "",
            "tempo_ate_aceite_minutos": round(tempo_ate_aceite, 2) if tempo_ate_aceite is not None else "",
            "tempo_ate_inicio_minutos": round(tempo_ate_inicio, 2) if tempo_ate_inicio is not None else "",
            "tempo_em_andamento_minutos": round(tempo_em_andamento, 2) if tempo_em_andamento is not None else "",
            "pings_trajeto": len(pings),
            "trajeto_svg": str(trajeto_svg) if trajeto_svg else "",
            "cliente_id": corrida.cliente_id,
            "cliente_user_id": corrida.cliente.user_id if corrida.cliente else "",
            "cliente_nome": corrida.cliente.nome if corrida.cliente else "",
            "cliente_telefone": self._telefone_perfil(corrida.cliente),
            "motorista_id": corrida.motorista_id or "",
            "motorista_user_id": corrida.motorista.user_id if corrida.motorista else "",
            "motorista_nome": corrida.motorista.nome if corrida.motorista else "",
            "motorista_telefone": self._telefone_perfil(corrida.motorista),
            "lugares": corrida.lugares,
            "origem_endereco": corrida.origem_endereco,
            "origem_lat": self._format_decimal(corrida.origem_lat),
            "origem_lng": self._format_decimal(corrida.origem_lng),
            "destino_endereco": corrida.destino_endereco,
            "destino_lat": self._format_decimal(corrida.destino_lat),
            "destino_lng": self._format_decimal(corrida.destino_lng),
        }
        return linha, duracao_min

    def _exportar_csv(self, queryset, output_path: Path, plot_dir: Path | None, tile_root: Path | None, tile_zoom: int) -> tuple[int, float | None]:
        fieldnames = [
            "corrida_id",
            "status",
            "criado_em",
            "atualizado_em",
            "aceita_em",
            "iniciada_em",
            "concluida_em",
            "duracao_minutos",
            "tempo_ate_aceite_minutos",
            "tempo_ate_inicio_minutos",
            "tempo_em_andamento_minutos",
            "pings_trajeto",
            "trajeto_svg",
            "cliente_id",
            "cliente_user_id",
            "cliente_nome",
            "cliente_telefone",
            "motorista_id",
            "motorista_user_id",
            "motorista_nome",
            "motorista_telefone",
            "lugares",
            "origem_endereco",
            "origem_lat",
            "origem_lng",
            "destino_endereco",
            "destino_lat",
            "destino_lng",
        ]
        total = 0
        duracoes = []
        with output_path.open("w", newline="", encoding="utf-8") as csvfile:
            writer = csv.DictWriter(csvfile, fieldnames=fieldnames)
            writer.writeheader()
            for corrida in queryset.iterator():
                linha, duracao_min = self._linha_corrida(corrida, plot_dir, tile_root, tile_zoom)
                writer.writerow(linha)
                total += 1
                if duracao_min is not None:
                    duracoes.append(duracao_min)

        duracao_media = None
        if duracoes:
            duracao_media = sum(duracoes) / len(duracoes)
        return total, duracao_media

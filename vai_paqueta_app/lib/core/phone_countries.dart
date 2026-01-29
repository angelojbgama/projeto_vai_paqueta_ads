import 'package:dio/dio.dart';

import '../services/api_client.dart';

class PhoneCountry {
  final String iso2;
  final String name;
  final String ddi;

  const PhoneCountry({
    required this.iso2,
    required this.name,
    required this.ddi,
  });

  String get flag => iso2ToFlag(iso2);

  String get label {
    final flagLabel = flag.isNotEmpty ? '$flag ' : '';
    return '$flagLabel+$ddi';
  }
}

String iso2ToFlag(String iso2) {
  if (iso2.length != 2) return '';
  final upper = iso2.toUpperCase();
  const base = 127397;
  final chars = upper.codeUnits.map((code) => base + code).toList();
  return String.fromCharCodes(chars);
}

class PhoneCountryService {
  static final List<PhoneCountry> fallback = [
    const PhoneCountry(iso2: 'BR', name: 'Brasil', ddi: '55'),
  ];

  static Future<List<PhoneCountry>>? _cache;

  static Future<List<PhoneCountry>> load({Dio? client}) {
    if (_cache != null) return _cache!;
    final dio = client ?? ApiClient.client;
    _cache = dio
        .get('/geo/countries/', options: Options(validateStatus: (_) => true))
        .then((resp) {
          if (resp.statusCode != 200) return fallback;
          final data = resp.data;
          final rawList = data is Map<String, dynamic> ? data['countries'] : data;
          if (rawList is! List) return fallback;
          final list = <PhoneCountry>[];
          for (final item in rawList) {
            if (item is! Map) continue;
            final ddi = (item['ddi'] ?? item['code'] ?? '').toString().trim();
            if (ddi.isEmpty) continue;
            final iso2 = (item['iso2'] ?? item['country'] ?? '').toString().trim().toUpperCase();
            final name = (item['name'] ?? item['nome'] ?? iso2).toString().trim();
            list.add(PhoneCountry(iso2: iso2, name: name, ddi: ddi));
          }
          if (list.isEmpty) return fallback;
          list.sort((a, b) => a.name.compareTo(b.name));
          return list;
        })
        .catchError((_) => fallback);
    return _cache!;
  }
}

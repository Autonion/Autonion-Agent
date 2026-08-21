class SystemAppInfo {
  final String name;
  final String path;
  final String source;

  const SystemAppInfo({
    required this.name,
    required this.path,
    this.source = 'system',
  });

  factory SystemAppInfo.fromJson(Map<String, dynamic> json) {
    return SystemAppInfo(
      name: json['name'] as String? ?? '',
      path: json['path'] as String? ?? '',
      source: json['source'] as String? ?? 'system',
    );
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'path': path,
        'source': source,
      };
}

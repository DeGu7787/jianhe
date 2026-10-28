class FeedbackCreated {
  const FeedbackCreated({
    required this.id,
    required this.status,
    required this.createdAt,
  });

  factory FeedbackCreated.fromJson(Map<String, Object?> json) {
    final id = json['id'];
    final status = json['status'];
    final createdAt = DateTime.tryParse(json['created_at'] as String? ?? '');
    if (id is! String || id.isEmpty || status is! String || createdAt == null) {
      throw const FormatException('Invalid feedback response.');
    }
    return FeedbackCreated(
      id: id,
      status: status,
      createdAt: createdAt.toUtc(),
    );
  }

  final String id;
  final String status;
  final DateTime createdAt;
}
